function _register_routes!()
    _ROUTES_REGISTERED[] && return

@websocket "/api/ws_generate" function(ws)
    for msg in ws
        data = json_parse(String(msg))
        master_file = data["master_file"]
        class_name = get(data, "class_name", nothing)
        output_name = get(data, "new_file_name", nothing)
        class_csv_file = nothing
        if isa(class_name, AbstractString) && !isempty(strip(class_name))
            class_csv_file = class_csv_path(class_name)
            if !isfile(class_csv_file)
                try
                    HTTP.WebSockets.send(ws, "Error: Class CSV not found for $(repr(class_name))\n")
                    HTTP.WebSockets.send(ws, "Done\n")
                catch
                end
                continue
            end
        end
        original_stdout = stdout
        rd, wr = redirect_stdout()
        
        reader_task = @async begin
            while !eof(rd)
                line = readline(rd)
                try
                    HTTP.WebSockets.send(ws, line * "\n")
                catch
                    break
                end
            end
        end
        
        try
            generate_assn_files(
                master_file;
                class_csv_file=class_csv_file,
                output_name=isa(output_name, AbstractString) ? output_name : nothing,
            )
            println("Done")
        catch e
            _print_friendly_error(e; bt=catch_backtrace())
            println("Done")
        finally
            redirect_stdout(original_stdout)
            close(wr)
            wait(reader_task)
        end
    end
end

@websocket "/api/ws_process" function(ws)
    for msg in ws
        data = json_parse(String(msg))
        tiff_file = String(get(data, "tiff_file", get(data, "scan_path", "")))
        non_biscuit = get(data, "non_biscuit", false) === true
        assn_versions_file = String(get(data, "assn_file", ""))
        corrections = get(data, "corrections", Dict{String, Any}())
        
        if !is_scan_path(tiff_file)
            throw(ArgumentError("Scan path was provided but could not be found: $tiff_file"))
        elseif !non_biscuit && !isfile(assn_versions_file)
            throw(ArgumentError("`assn_versions_file` was provided but could not be found: $assn_versions_file"))
        end

        class_csv_file = nothing
        if non_biscuit
            class_name = get(data, "class_name", nothing)
            if isa(class_name, AbstractString) && !isempty(strip(class_name))
                class_csv_file = class_csv_path(class_name)
                if !isfile(class_csv_file)
                    try
                        HTTP.WebSockets.send(ws, "Error: Class CSV not found for $(repr(class_name))\n")
                        HTTP.WebSockets.send(ws, "Done\n")
                    catch
                    end
                    continue
                end
            end
        end

        original_stdout = stdout
        rd, wr = redirect_stdout()
        reader_task = @async begin
            while !eof(rd)
                line = readline(rd)
                try
                    HTTP.WebSockets.send(ws, line * "\n")
                catch
                    break
                end
            end
        end
        
        try
            if non_biscuit
                process_non_biscuit_scans(
                    tiff_file;
                    pages_per_student=_required_positive_int(get(data, "pages_per_student", nothing), "Num Pages Per Student"),
                    total_points=_required_nonnegative_number(get(data, "total_points", nothing), "Total Points"),
                    assn_type=String(get(data, "assn_type", "")),
                    output_name=_optional_path(get(data, "new_file_name", nothing)),
                    class_csv_file=class_csv_file,
                )
            else
                # Name guessing uses the class's app-managed name reader, resolved from the
                # roster inside the archive, so the user never picks a file.
                namereader_file = nothing
                if get(data, "guess_names", false) === true
                    status = archive_roster_status(assn_versions_file)
                    namereader_file = class_namereader_for_guessing(get(status, "class_name", nothing))
                    namereader_file === nothing && println(
                        "Skipping name guesses: no trained name reader for this assignment's class."
                    )
                end
                process_scans(
                    tiff_file;
                    assn_versions_file=assn_versions_file,
                    corrections=corrections,
                    namereader_file=namereader_file,
                    output_name=_optional_path(get(data, "new_file_name", nothing)),
                )
            end
            tmp_dir = STATE["temp_archive_dir"]
            if isa(tmp_dir, AbstractString) && !isdir(tmp_dir)
                STATE["temp_archive_dir"] = nothing
                STATE["assn_archive_path"] = nothing
            end
            println("Done")
        catch e
            _print_friendly_error(e; bt=catch_backtrace())
            println("Done")
        finally
            redirect_stdout(original_stdout)
            close(wr)
            wait(reader_task)
        end
    end
end

@websocket "/api/ws_train_namereader" function(ws)
    stop_flag = Ref(false)
    save_on_stop = Ref(true)
    train_task = nothing
    original_stdout = stdout
    rd, wr = redirect_stdout()
    reader_task = @async begin
        while !eof(rd)
            line = readline(rd)
            try
                HTTP.WebSockets.send(ws, line * "\n")
            catch
                break
            end
        end
    end
    try
        for msg in ws
            data = json_parse(String(msg))
            if get(data, "cancel", false) == true
                stop_flag[] = true
                save_on_stop[] = false
                println("Cancel requested; stopping without saving.")
                flush(stdout)
                continue
            elseif get(data, "stop", false) == true
                stop_flag[] = true
                save_on_stop[] = true
                println("Stop requested; finishing this epoch and saving.")
                flush(stdout)
                continue
            end
            train_task === nothing || continue

            train_task = @async begin
                try
                    class_name = _required_class_name(get(data, "class_name", nothing))
                    fine_tune = get(data, "fine_tune", false) === true
                    handwriting_dir = class_name_images_dir(class_name)
                    isdir(handwriting_dir) || throw(ArgumentError(
                        "No stored handwriting for $(class_name) yet. Grade an assignment with a " *
                        "name line or name table and run Finish & Export to collect some."
                    ))
                    dest = class_namereader_path(class_name)
                    sidecar = class_namereader_sidecar_path(class_name)
                    background_dir = _optional_path(get(data, "background_dir", nothing))
                    bg = background_dir === nothing ? NameReader.background_training_dir() : background_dir

                    init_model = nothing
                    previous_split = nothing
                    if fine_tune
                        isfile(dest) || throw(ArgumentError(
                            "There is no name reader for $(class_name) to fine-tune yet; train one first."
                        ))
                        init_model = load_name_reader(dest).gallery.model
                        sidecar_data = NameReader.read_training_sidecar(sidecar)
                        if sidecar_data !== nothing
                            recorded = get(sidecar_data, "students", nothing)
                            isa(recorded, AbstractDict) && (previous_split = recorded)
                        end
                    end

                    println(fine_tune ? "Fine-tuning NameReader" : "Training NameReader")
                    println("  class: ", class_name)
                    println("  handwriting: ", handwriting_dir)
                    println("  backgrounds: ", bg)
                    println("  output: ", dest)
                    train_name_reader(
                        handwriting_dir;
                        background_dir=bg,
                        output_path=dest,
                        sidecar_path=sidecar,
                        init_model=init_model,
                        previous_split=previous_split,
                        epochs=fine_tune ? FINE_TUNE_EPOCHS : TRAIN_EPOCHS,
                        should_stop=() -> stop_flag[],
                        save_on_stop=() -> save_on_stop[],
                    )
                    println("Done")
                catch e
                    _print_friendly_error(e; bt=catch_backtrace())
                    println("Done")
                end
            end
        end
    finally
        stop_flag[] = true
        train_task !== nothing && wait(train_task)
        redirect_stdout(original_stdout)
        close(wr)
        wait(reader_task)
    end
end

@get "/api/list_files" function(req::HTTP.Request)
    query = HTTP.URIs.queryparams(HTTP.URI(req.target))
    req_dir = try
        resolve_under_workspace(get(query, "dir", "."))
    catch
        "."
    end
    entries = []
    # Add parent directory option if not at workspace root
    if req_dir != "."
        parent = dirname(req_dir)
        push!(entries, Dict("name" => "..", "is_dir" => true, "path" => parent == "." ? "." : parent))
    end
    for name in readdir(req_dir)
        if startswith(name, ".") continue end # skip hidden files
        path = req_dir == "." ? name : joinpath(req_dir, name)
        push!(entries, Dict("name" => name, "is_dir" => isdir(path), "path" => replace(path, "\\" => "/")))
    end
    return Dict("status" => "success", "current_dir" => req_dir, "entries" => entries)
end

@post "/api/upload_grade_context" function(req::HTTP.Request)
    data = Oxygen.json(req)
    assn_file = get(data, "assn_file", "")
    use_existing_tmp = get(data, "use_existing_tmp", false)
    replace_existing_tmp = get(data, "replace_existing_tmp", false)
    if !isa(use_existing_tmp, Bool)
        return Dict("status" => "error", "message" => "`use_existing_tmp` must be a boolean when provided.")
    elseif !isa(replace_existing_tmp, Bool)
        return Dict("status" => "error", "message" => "`replace_existing_tmp` must be a boolean when provided.")
    elseif use_existing_tmp && replace_existing_tmp
        return Dict("status" => "error", "message" => "`use_existing_tmp` and `replace_existing_tmp` cannot both be true.")
    end
    if !isa(assn_file, AbstractString) || isempty(strip(assn_file))
        return Dict("status" => "error", "message" => "`assn_file` is required and must be a non-empty .assn path.")
    elseif !endswith(lowercase(assn_file), ".assn")
        return Dict("status" => "error", "message" => "`assn_file` must point to a .assn archive.")
    elseif !isfile(assn_file)
        return Dict("status" => "error", "message" => "Could not find .assn archive at: $assn_file")
    end
    prev_archive = STATE["assn_archive_path"]
    prev_tmp = STATE["temp_archive_dir"]
    if isa(prev_archive, AbstractString) && isa(prev_tmp, AbstractString) && isdir(prev_tmp) &&
       abspath(String(prev_archive)) != abspath(String(assn_file))
        try
            make_archive_from_dir(prev_tmp, String(prev_archive); rebuild=true)
        catch
        end
        try
            rm(prev_tmp; recursive=true, force=true)
        catch
        end
        STATE["temp_archive_dir"] = nothing
        STATE["assn_archive_path"] = nothing
    end
    STATE["assn_archive_path"] = assn_file
    try
        STATE["temp_archive_dir"] = extract_archive(assn_file; use_existing_tmp=use_existing_tmp)
    catch e
        if isa(e, ArchiveUtils.ExistingTempArchiveError)
            if replace_existing_tmp
                try
                    rm(e.temp_dir_path; recursive=true, force=true)
                    STATE["temp_archive_dir"] = extract_archive(assn_file; use_existing_tmp=false)
                catch inner_e
                    return Dict("status" => "error", "message" => "Could not replace existing temp archive data: $inner_e")
                end
            else
                return Dict(
                    "status" => "confirm_existing_tmp",
                    "message" => "Data from a previous session was found for this .assn file at $(e.temp_dir_path).\nChoose one option:",
                    "temp_dir" => e.temp_dir_path,
                )
            end
        else
            return Dict("status" => "error", "message" => "Could not extract .assn archive: $e")
        end
    end
    saved_grading_data = _read_file_from_temp("grading_data.json"; give_default=true)
    grading_data = try
        isempty(saved_grading_data) ? _build_grading_data_from_archive() : saved_grading_data
    catch e
        return Dict("status" => "error", "message" => "Could not build grading data: $e")
    end
    roster_status = try
        roster_sync_status(find_roster_csv_path(String(STATE["temp_archive_dir"])))
    catch
        nothing
    end
    return Dict("status" => "success", "grading_data" => grading_data, "roster_status" => roster_status)
end

@get "/api/get_students" function(req::HTTP.Request)
    if isnothing(STATE["temp_archive_dir"])
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    roster = try
        _read_roster_from_temp(; give_default=true)
    catch e
        return Dict("status" => "error", "message" => "Failed to read class roster CSV: $e")
    end
    if roster === nothing
        # Optional: archives without a class roster still allow free-text name assignment.
        return Dict("status" => "success", "students" => String[], "class_name" => nothing)
    end
    nt = roster.table
    if !haskey(nt, :Student)
        return Dict("status" => "error", "message" => "Class roster CSV is missing a `Student` column")
    end
    return Dict(
        "status" => "success",
        "students" => String.(nt.Student),
        "class_name" => roster.class_name,
    )
end

@get "/api/get_master_json" function(req::HTTP.Request)
    if isnothing(STATE["temp_archive_dir"])
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    return Dict("master" => _read_file_from_temp("master.json"))
end

@get "/api/get_scan_results" function(req::HTTP.Request)
    if isnothing(STATE["temp_archive_dir"])
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    try
        results = _read_file_from_temp("annotated/scan_results.json")
        return Dict("status" => "success", "scan_results" => results)
    catch e
        return Dict("status" => "error", "message" => "Could not read scan results: $e")
    end
end

@get "/api/annotated_image/{dir}/{file}" function(req::HTTP.Request, dir::String, file::String)
    temp_dir = STATE["temp_archive_dir"]
    if isnothing(temp_dir)
        return HTTP.Response(400, "Assignment archive is not configured.")
    end
    if !isdir(temp_dir)
        return HTTP.Response(404, "Temporary archive directory not found.")
    end
    if !occursin(r"^[a-zA-Z0-9_]+$", dir) || !occursin(r"^[a-zA-Z0-9_\.]+$", file)
        return HTTP.Response(400, "Invalid path parameters.")
    end
    page_file = joinpath(temp_dir, "annotated", dir, file)
    if !isfile(page_file)
        return HTTP.Response(404, "Annotated image not found: $dir/$file")
    end
    return HTTP.Response(200, [
        "Content-Type" => "image/png",
        "Cache-Control" => "no-store, no-cache, must-revalidate",
        "Pragma" => "no-cache",
    ], read(page_file))
end

# Annotated scans are stored as one PNG per page (e.g. annotated/assn_<id>/0001.png). The client
# renders each page as its own image, so it first asks how many pages an assn has, then requests them
# individually via the endpoint below.
@get "/api/annotated_page_count/{assn_id}" function(req::HTTP.Request, assn_id::String)
    temp_dir = STATE["temp_archive_dir"]
    if isnothing(temp_dir)
        return HTTP.Response(400, "Assignment archive is not configured.")
    end
    if !isdir(temp_dir)
        return HTTP.Response(404, "Temporary archive directory not found.")
    end
    test_dir = joinpath(temp_dir, "annotated", "assn_$assn_id")
    if !isdir(test_dir)
        return HTTP.Response(404, "Annotated scan not found for assn $assn_id")
    end
    num_pages = count(name -> endswith(lowercase(name), ".png"), readdir(test_dir))
    return Dict("num_pages" => num_pages)
end

@get "/api/annotated_page_png/{assn_id}/{page}" function(req::HTTP.Request, assn_id::String, page::String)
    temp_dir = STATE["temp_archive_dir"]
    if isnothing(temp_dir)
        return HTTP.Response(400, "Assignment archive is not configured.")
    end
    if !isdir(temp_dir)
        return HTTP.Response(404, "Temporary archive directory not found.")
    end
    page_num = tryparse(Int, page)
    if isnothing(page_num) || page_num < 1
        return HTTP.Response(400, "Invalid page number: $page")
    end
    page_file = joinpath(temp_dir, "annotated", "assn_$assn_id", string(lpad(page_num, 4, '0'), ".png"))
    if !isfile(page_file)
        return HTTP.Response(404, "Annotated page $page_num not found for assn $assn_id")
    end
    return HTTP.Response(200, [
        "Content-Type" => "image/png",
        "Cache-Control" => "no-store, no-cache, must-revalidate",
        "Pragma" => "no-cache",
    ], read(page_file))
end

@post "/api/save_grading_data" function(req::HTTP.Request)
    grading_data = Oxygen.json(req)
    temp_dir = STATE["temp_archive_dir"]
    if isnothing(temp_dir)
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    try
        output_file = joinpath(temp_dir, "grading_data.json")
        open(output_file, "w") do f
            json_print(f, grading_data)
        end
    catch e
        return Dict("status" => "error", "message" => "Failed to save work to archive: $e")
    end
    return Dict("status" => "success")
end

# Recompress the unpacked temp dir back over its source .assn archive. Triggered by "Save Work" (in
# addition to the lightweight grading_data.json commit above) and mirrored by the atexit handler.
@post "/api/save_archive" function(req::HTTP.Request)
    archive_path = STATE["assn_archive_path"]
    temp_dir = STATE["temp_archive_dir"]
    if isnothing(archive_path) || isnothing(temp_dir)
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    try
        make_archive_from_dir(temp_dir, archive_path; rebuild=true)
    catch e
        return Dict("status" => "error", "message" => "Failed to save work to .assn archive: $e")
    end
    return Dict("status" => "success")
end

# Drop the unpacked temp dir without repacking. Used when verification finishes (process_scans
# already rewrote the .assn archive) so `.assn.tmp` is not left behind.
@post "/api/clear_archive_context" function(req::HTTP.Request)
    temp_dir = STATE["temp_archive_dir"]
    if isa(temp_dir, String) && isdir(temp_dir)
        try
            rm(temp_dir; force=true, recursive=true)
        catch e
            return Dict("status" => "error", "message" => "Failed to remove temp archive directory: $e")
        end
    end
    STATE["temp_archive_dir"] = nothing
    STATE["assn_archive_path"] = nothing
    return Dict("status" => "success")
end

# Save grading work, repack `.assn`, and clear the temp dir (used when returning Home from grading).
@post "/api/close_grading_session" function(req::HTTP.Request)
    archive_path = STATE["assn_archive_path"]
    temp_dir = STATE["temp_archive_dir"]
    if isnothing(archive_path) || isnothing(temp_dir)
        STATE["temp_archive_dir"] = nothing
        STATE["assn_archive_path"] = nothing
        return Dict("status" => "success", "message" => "No grading session was open.")
    end
    try
        make_archive_from_dir(temp_dir, archive_path; rebuild=true)
    catch e
        return Dict("status" => "error", "message" => "Failed to save work to .assn archive: $e")
    end
    try
        rm(temp_dir; force=true, recursive=true)
    catch e
        return Dict("status" => "error", "message" => "Saved archive, but failed to remove temp directory: $e")
    end
    STATE["temp_archive_dir"] = nothing
    STATE["assn_archive_path"] = nothing
    return Dict("status" => "success")
end

# Detach the extracted `.assn.tmp` without packing or deleting it. Home uses this
# so "Go home without saving?" leaves the temp folder for a later resume prompt.
@post "/api/abandon_archive_session" function(req::HTTP.Request)
    STATE["temp_archive_dir"] = nothing
    STATE["assn_archive_path"] = nothing
    return Dict("status" => "success")
end

# --- Managed classes (roster CSVs) ---

@get "/api/classes" function(req::HTTP.Request)
    try
        classes = list_classes()
        for cls in classes
            cls["has_namereader"] = class_namereader_for_guessing(get(cls, "class_name", nothing)) !== nothing
        end
        return Dict("status" => "success", "classes" => classes)
    catch e
        return Dict("status" => "error", "message" => "Failed to list classes: $e")
    end
end

@post "/api/classes" function(req::HTTP.Request)
    data = Oxygen.json(req)
    class_name = string(get(data, "class_name", ""))
    csv_text = get(data, "csv_text", nothing)
    source_csv = string(get(data, "source_csv", ""))
    try
        info = if isa(csv_text, AbstractString) && !isempty(csv_text)
            add_class_from_csv_text(class_name, csv_text)
        else
            add_class(class_name, source_csv)
        end
        return Dict("status" => "success", "class" => info)
    catch e
        return Dict("status" => "error", "message" => sprint(showerror, e))
    end
end

@post "/api/classes/delete" function(req::HTTP.Request)
    data = Oxygen.json(req)
    class_name = string(get(data, "class_name", ""))
    try
        delete_class(class_name)
        return Dict("status" => "success")
    catch e
        return Dict("status" => "error", "message" => sprint(showerror, e))
    end
end

@post "/api/classes/reveal" function(req::HTTP.Request)
    data = Oxygen.json(req)
    class_name = string(get(data, "class_name", ""))
    try
        path = class_csv_path(class_name)
        reveal_path_in_file_manager(path)
        return Dict("status" => "success", "path" => abspath(path))
    catch e
        return Dict("status" => "error", "message" => sprint(showerror, e))
    end
end

# Export detailed + simplified score CSVs next to the loaded .assn archive.
@post "/api/export_csv" function(req::HTTP.Request)
    temp_dir = STATE["temp_archive_dir"]
    archive_path = STATE["assn_archive_path"]
    if isnothing(temp_dir) || isnothing(archive_path)
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    try
        grading_data = _read_file_from_temp("grading_data.json"; give_default=true)
        master = _read_file_from_temp("master.json")
        students_table = nothing
        class_name = nothing
        try
            r = _read_roster_from_temp(; give_default=true)
            if r !== nothing
                students_table = r.table
                class_name = r.class_name
            end
        catch
        end
        detailed_path, scores_path = export_score_csvs(;
            grading_data,
            master,
            students_table,
            archive_path,
            class_name,
        )
        return Dict(
            "status" => "success",
            "detailed_csv_path" => detailed_path,
            "scores_csv_path" => scores_path,
        )
    catch e
        return Dict("status" => "error", "message" => "Failed to export CSV: $e")
    end
end

# Compile per-student feedback PDFs next to the loaded .assn archive (outside the temp dir).
@post "/api/export_feedback" function(req::HTTP.Request)
    temp_dir = STATE["temp_archive_dir"]
    archive_path = STATE["assn_archive_path"]
    if isnothing(temp_dir) || isnothing(archive_path)
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    grading_data_file = joinpath(temp_dir, "grading_data.json")
    annotated_scan_folder = joinpath(temp_dir, "annotated")
    if !isfile(grading_data_file)
        return Dict("status" => "error", "message" => "Missing grading_data.json; save grading work first.")
    end
    if !isdir(annotated_scan_folder)
        return Dict("status" => "error", "message" => "Missing annotated scans folder.")
    end
    output_dir = joinpath(dirname(archive_path), first(splitext(basename(archive_path))) * "_feedback")
    try
        compile_feedback_bundle(;
            grading_data_file,
            annotated_scan_folder,
            output_dir,
        )
        return Dict("status" => "success", "output_dir" => output_dir)
    catch e
        return Dict("status" => "error", "message" => "Failed to export feedback PDFs: $e")
    end
end

# Label the archive's saved name crops with the names grading settled on, then merge them
# into the class's app-managed training store.
@post "/api/export_name_training_data" function(req::HTTP.Request)
    temp_dir = STATE["temp_archive_dir"]
    archive_path = STATE["assn_archive_path"]
    if isnothing(temp_dir) || isnothing(archive_path)
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    processed_file = joinpath(temp_dir, "processed_assn_data.json")
    grading_data_file = joinpath(temp_dir, "grading_data.json")
    if !isfile(processed_file)
        return Dict("status" => "error", "message" => "Missing processed_assn_data.json.")
    end
    if !isfile(grading_data_file)
        return Dict("status" => "error", "message" => "Missing grading_data.json; save grading work first.")
    end
    class_name = nothing
    try
        roster = _read_roster_from_temp(; give_default=true)
        roster === nothing || (class_name = roster.class_name)
    catch
        # Handled as a missing class name below.
    end
    if class_name === nothing
        return Dict(
            "status" => "error",
            "message" => "This archive has no class roster CSV, so name training data has nowhere to go.",
        )
    end
    annotated_scan_folder = joinpath(temp_dir, "annotated")
    try
        result = export_name_training_data(;
            processed_assn_data_file=processed_file,
            grading_data_file=grading_data_file,
            archive_dir=String(temp_dir),
            class_name=class_name,
            annotated_scan_folder=isdir(annotated_scan_folder) ? annotated_scan_folder : nothing,
        )
        result === nothing && return Dict("status" => "success", "exported" => false)
        return Dict(
            "status" => "success",
            "exported" => result.added > 0,
            "class_name" => class_name,
            "output_dir" => result.images_dir,
            "added" => result.added,
            "skipped" => result.skipped,
            "students" => result.students,
            "class_registered" => isfile(class_csv_path(class_name)),
        )
    catch e
        return Dict("status" => "error", "message" => "Failed to store name training data: $e")
    end
end

# What the Name Recognition screen can offer for a class: what is stored, whether a
# .namereader exists, and how much of the store it has never seen.
@get "/api/class_name_data" function(req::HTTP.Request)
    query = HTTP.URIs.queryparams(HTTP.URI(req.target))
    class_name = _optional_path(get(query, "class_name", nothing))
    if class_name === nothing
        return Dict("status" => "error", "message" => "`class_name` is required.")
    end
    try
        summary = class_name_data_summary(class_name)
        summary["status"] = "success"
        return summary
    catch e
        return Dict("status" => "error", "message" => "Could not read name data for $(class_name): $e")
    end
end

# Class + name-reader context for a .assnversions / .assn path, used to offer name guessing
# and to flag a roster that has drifted from the app's copy.
@post "/api/archive_class_info" function(req::HTTP.Request)
    data = Oxygen.json(req)
    archive_file = _optional_path(get(data, "archive_file", nothing))
    if archive_file === nothing
        return Dict("status" => "error", "message" => "`archive_file` is required.")
    elseif !isfile(archive_file)
        return Dict("status" => "error", "message" => "Could not find archive at: $archive_file")
    end
    try
        status = archive_roster_status(archive_file)
        class_name = get(status, "class_name", nothing)
        namereader = class_namereader_for_guessing(class_name)
        status["status"] = "success"
        status["has_namereader"] = namereader !== nothing
        status["namereader_path"] = namereader
        return status
    catch e
        return Dict("status" => "error", "message" => "Could not read the archive's class roster: $e")
    end
end

# Replace the roster inside a .assnversions / .assn with the app's copy. The archive has to be
# repacked, so grading uses the open-archive route below instead.
@post "/api/archive_apply_app_roster" function(req::HTTP.Request)
    data = Oxygen.json(req)
    archive_file = _optional_path(get(data, "archive_file", nothing))
    if archive_file === nothing
        return Dict("status" => "error", "message" => "`archive_file` is required.")
    elseif !isfile(archive_file)
        return Dict("status" => "error", "message" => "Could not find archive at: $archive_file")
    end
    open_archive = STATE["assn_archive_path"]
    if isa(open_archive, AbstractString) && abspath(String(open_archive)) == abspath(archive_file)
        return Dict(
            "status" => "error",
            "message" => "That archive is open for grading; close it before updating its roster.",
        )
    end
    try
        status = with_archive_dir(String(archive_file)) do archive_dir
            result = apply_app_roster_to_dir(archive_dir)
            make_archive_from_dir(archive_dir, String(archive_file); rebuild=true)
            result
        end
        status["status"] = "success"
        status["differs"] = false
        return status
    catch e
        return Dict("status" => "error", "message" => "Could not update the archive's roster: $e")
    end
end

# Patch the roster in the unpacked archive currently open for grading. It is folded back into
# the .assn the same way the rest of the grading work is.
@post "/api/open_archive_apply_app_roster" function(req::HTTP.Request)
    temp_dir = STATE["temp_archive_dir"]
    if isnothing(temp_dir)
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    try
        status = apply_app_roster_to_dir(String(temp_dir))
        status["status"] = "success"
        status["differs"] = false
        return status
    catch e
        return Dict("status" => "error", "message" => "Could not update the roster: $e")
    end
end

# One-time desktop OAuth using the shipped client; writes ~/.config/biscuit/google_drive_token.json.
@post "/api/authorize_google_drive" function(req::HTTP.Request)
    if !google_drive_client_available()
        return Dict(
            "status" => "error",
            "message" => "Shipped Google Drive client file not found at $(google_drive_client_path()).",
        )
    end
    try
        token_path = authorize_google_drive()
        return Dict(
            "status" => "success",
            "token_path" => token_path,
            "message" => "Google Drive authorized.",
        )
    catch e
        return Dict("status" => "error", "message" => "Google Drive authorization failed: $(_friendly_drive_error(e))")
    end
end

@get "/api/drive_credentials_status" function(req::HTTP.Request)
    token_path = google_drive_token_path()
    linked = google_drive_credentials_linked(token_path)
    client_ok = google_drive_client_available()
    has_student_email = false
    roster_present = false
    class_name = nothing
    if !isnothing(STATE["temp_archive_dir"])
        try
            roster = _read_roster_from_temp(; give_default=true)
            if roster !== nothing
                roster_present = true
                class_name = roster.class_name
                has_student_email = students_table_has_email(roster.table)
            end
        catch
            # Ignore roster read errors for status; upload path will surface them.
        end
    end
    missing = String[]
    !client_ok && push!(missing, "This app build is missing its Google Drive client file.")
    if !roster_present
        push!(missing, "No class roster CSV is in this assignment archive (select a class when creating the assignment).")
    end
    return Dict(
        "status" => "success",
        "linked" => linked,
        "needs_authorization" => client_ok && !linked,
        "client_available" => client_ok,
        "has_student_email" => has_student_email,
        "roster_present" => roster_present,
        "class_name" => class_name,
        "can_upload" => client_ok && roster_present,
        "missing" => missing,
        "token_path" => linked ? token_path : nothing,
    )
end

function _drive_upload_context(feedback_dir::AbstractString)
    temp_dir = STATE["temp_archive_dir"]
    archive_path = STATE["assn_archive_path"]
    token_path = google_drive_token_path()
    if isnothing(temp_dir) || isnothing(archive_path)
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    if isempty(feedback_dir)
        return Dict("status" => "error", "message" => "feedback_dir is required")
    end
    if !isdir(feedback_dir)
        return Dict("status" => "error", "message" => "Feedback directory not found: $feedback_dir")
    end
    if !google_drive_credentials_linked(token_path)
        return Dict(
            "status" => "error",
            "message" => "Google Drive is not linked yet. Authorize when prompted, then try again.",
        )
    end
    master = try
        _read_file_from_temp("master.json")
    catch e
        return Dict("status" => "error", "message" => "Could not read master.json: $e")
    end
    assn_type = string(get(master, "assn_type", ""))
    if !(assn_type in ("quiz", "worksheet", "exam"))
        return Dict(
            "status" => "error",
            "message" => "`master.json` must include assn_type \"quiz\", \"worksheet\", or \"exam\"",
        )
    end
    roster = try
        _read_roster_from_temp(; give_default=true)
    catch e
        return Dict("status" => "error", "message" => "Failed to read class roster CSV: $e")
    end
    if roster === nothing
        return Dict(
            "status" => "error",
            "message" => "No class roster CSV in the assignment archive",
        )
    end
    students = roster.table
    if !haskey(students, :Student)
        return Dict(
            "status" => "error",
            "message" => "Class roster CSV must include a `Student` column",
        )
    end
    assn_name = first(splitext(basename(archive_path)))
    return Dict(
        "status" => "ok",
        "token_path" => String(token_path),
        "feedback_dir" => String(feedback_dir),
        "students" => students,
        "assn_type" => assn_type,
        "assn_name" => assn_name,
        "class_name" => roster.class_name,
    )
end

# Preview which feedback PDFs would overwrite an existing Drive file of the same assignment name.
@post "/api/drive_upload_preview" function(req::HTTP.Request)
    data = Oxygen.json(req)
    feedback_dir = string(get(data, "feedback_dir", ""))
    ctx = _drive_upload_context(feedback_dir)
    ctx["status"] != "ok" && return ctx
    try
        preview = preview_drive_upload_conflicts(
            ctx["token_path"],
            ctx["feedback_dir"],
            ctx["students"],
            ctx["assn_type"],
            ctx["assn_name"],
            ctx["class_name"],
        )
        return Dict("status" => "success", "preview" => preview)
    catch e
        return Dict("status" => "error", "message" => "Failed to preview Google Drive upload: $(_friendly_drive_error(e))")
    end
end

# Stream Google Drive upload logs + final summary over a websocket.
@websocket "/api/ws_upload_drive" function(ws)
    for msg in ws
        data = json_parse(String(msg))
        feedback_dir = string(get(data, "feedback_dir", ""))
        duplicate_policy = string(get(data, "duplicate_policy", "add_new"))
        ctx = _drive_upload_context(feedback_dir)
        if ctx["status"] != "ok"
            HTTP.WebSockets.send(ws, "Error: $(ctx["message"])\n")
            HTTP.WebSockets.send(ws, "Done\n")
            continue
        end

        original_stdout = stdout
        rd, wr = redirect_stdout()
        reader_task = @async begin
            while !eof(rd)
                line = readline(rd)
                try
                    HTTP.WebSockets.send(ws, line * "\n")
                catch
                    break
                end
            end
        end

        summary = nothing
        try
            summary = upload_feedback_pdfs(
                ctx["token_path"],
                ctx["feedback_dir"],
                ctx["students"],
                ctx["assn_type"],
                ctx["assn_name"],
                ctx["class_name"];
                duplicate_policy=duplicate_policy,
            )
            try
                patch_detailed_csv_drive_links_after_upload(summary)
            catch e
                println("Warning: could not add Google Drive links to the detailed CSV: $e")
            end
            println("SUMMARY:" * json_string(Dict(
                "status" => "success",
                "summary" => summary,
                "assn_type" => ctx["assn_type"],
                "assn_name" => ctx["assn_name"],
                "class_name" => ctx["class_name"],
            )))
            println("Done")
        catch e
            println("Error: $(_friendly_drive_error(e))")
            println("Done")
        finally
            redirect_stdout(original_stdout)
            close(wr)
            wait(reader_task)
        end
    end
end

# Kept for non-streaming callers; prefer ws_upload_drive for UI progress.
@post "/api/upload_feedback_drive" function(req::HTTP.Request)
    data = Oxygen.json(req)
    feedback_dir = string(get(data, "feedback_dir", ""))
    duplicate_policy = string(get(data, "duplicate_policy", "add_new"))
    ctx = _drive_upload_context(feedback_dir)
    ctx["status"] != "ok" && return ctx
    try
        summary = upload_feedback_pdfs(
            ctx["token_path"],
            ctx["feedback_dir"],
            ctx["students"],
            ctx["assn_type"],
            ctx["assn_name"],
            ctx["class_name"];
            duplicate_policy=duplicate_policy,
        )
        try
            patch_detailed_csv_drive_links_after_upload(summary)
        catch e
            @warn "Could not add Google Drive links to the detailed CSV" exception=e
        end
        return Dict(
            "status" => "success",
            "summary" => summary,
            "assn_type" => ctx["assn_type"],
            "assn_name" => ctx["assn_name"],
            "class_name" => ctx["class_name"],
        )
    catch e
        return Dict("status" => "error", "message" => "Failed to upload feedback to Google Drive: $(_friendly_drive_error(e))")
    end
end

# --- Master JSON & Assignment Builder Endpoints ---

@post "/api/validate_master_json" function(req::HTTP.Request)
    data = Oxygen.json(req)
    try
        if haskey(data, "path")
            raw_path = string(data["path"])
            if isempty(strip(raw_path))
                return Dict("status" => "error", "message" => "No file path provided.")
            end
            target_path = try
                resolve_under_workspace(raw_path)
            catch
                raw_path
            end
            if !isfile(target_path)
                return Dict("status" => "error", "message" => "File not found: $raw_path")
            end
            validate_master_json_file(target_path)
            return Dict("status" => "success", "message" => "master .json validated")
        elseif haskey(data, "master")
            master_dict = _normalize_json_types(data["master"])
            if !isa(master_dict, AbstractDict) && !isa(master_dict, Dict)
                return Dict("status" => "error", "message" => "Top-level value must be a JSON object.")
            end
            validate_master_json(Dict{String, Any}(string(k) => v for (k, v) in pairs(master_dict)))
            return Dict("status" => "success", "message" => "master .json validated")
        elseif haskey(data, "json_string")
            parsed = json_parse(string(data["json_string"]))
            if !isa(parsed, AbstractDict) && !isa(parsed, Dict)
                return Dict("status" => "error", "message" => "Top-level value must be a JSON object.")
            end
            validate_master_json(Dict{String, Any}(string(k) => v for (k, v) in pairs(parsed)))
            return Dict("status" => "success", "message" => "master .json validated")
        else
            return Dict("status" => "error", "message" => "Missing path or master data.")
        end
    catch e
        msg = sprint(showerror, e)
        msg = replace(msg, r"^ArgumentError:\s*" => "")
        return Dict("status" => "error", "message" => msg)
    end
end

@post "/api/cleanup_builder_preview" function(req::HTTP.Request)
    _cleanup_builder_preview_dir!()
    return Dict("status" => "success")
end

@post "/api/preview_master_json" function(req::HTTP.Request)
    data = Oxygen.json(req)
    master_dict = if haskey(data, "master")
        _normalize_json_types(data["master"])
    elseif haskey(data, "json_string")
        try
            json_parse(string(data["json_string"]))
        catch e
            return Dict("status" => "error", "message" => "Invalid JSON syntax: $(sprint(showerror, e))")
        end
    else
        return Dict("status" => "error", "message" => "Missing master json payload.")
    end

    if !isa(master_dict, AbstractDict) && !isa(master_dict, Dict)
        return Dict("status" => "error", "message" => "Master JSON must be a JSON object.")
    end
    master_data = Dict{String, Any}(string(k) => v for (k, v) in pairs(master_dict))

    # Validate before attempting rendering
    try
        validate_master_json(master_data)
    catch e
        msg = sprint(showerror, e)
        msg = replace(msg, r"^ArgumentError:\s*" => "")
        return Dict("status" => "error", "message" => msg)
    end

    return lock(PREVIEW_COMPILE_LOCK) do
        preview_dir, preview_id, work_dir = _ensure_builder_preview_dir!(; source_path=get(data, "source_path", nothing))
        _clear_full_preview_pages!(preview_dir)

        master_file_path = joinpath(preview_dir, "master.json")
        open(master_file_path, "w") do f
            json_print(f, master_data)
        end

        stderr_buf = IOBuffer()
        stdout_buf = IOBuffer()
        try
            selection_file = GenerateAssnFiles.generate_selection_json(;
                master_file=master_file_path,
                output_dir=preview_dir,
                preview=true,
            )

            source_file = Commands.assn_typst_file()
            out_pattern = joinpath(preview_dir, "page-{p}.png")
            will_print_double_sided = Bool(get(master_data, "will_print_double_sided", true))
            work_abs = abspath(work_dir)

            args = [
                "compile",
                "--root", ".",
                "--input", "master=$(_rel_under(work_abs, master_file_path))",
                "--input", "selection=$(_rel_under(work_abs, selection_file))",
                "--input", "single_doc_export=true",
                "--input", "will_print_double_sided=$will_print_double_sided",
                "--ppi", "144",
                "-",
                _rel_under(work_abs, out_pattern),
            ]

            cmd = pipeline(
                Cmd(`typst $args`; dir=work_abs);
                stdin=source_file,
                stdout=stdout_buf,
                stderr=stderr_buf,
            )
            run(cmd)

            pages = Int[]
            for file_name in readdir(preview_dir)
                m = match(r"^page-(\d+)\.png$", file_name)
                if m !== nothing
                    push!(pages, parse(Int, m.captures[1]))
                end
            end
            sort!(pages)

            if isempty(pages)
                return Dict("status" => "error", "message" => "No pages were generated by Typst.")
            end

            return Dict(
                "status" => "success",
                "preview_id" => preview_id,
                "page_count" => length(pages),
                "pages" => pages,
            )
        catch e
            err_details = String(take!(stderr_buf))
            msg = if !isempty(strip(err_details))
                strip(err_details)
            else
                sprint(showerror, e)
            end
            return Dict("status" => "error", "message" => "Preview generation failed:\n" * msg)
        end
    end
end

@get "/api/preview_page/{preview_id}/{page}" function(req::HTTP.Request, preview_id::String, page::String)
    curr_id = get(STATE, "preview_id", nothing)
    preview_dir = get(STATE, "preview_dir", nothing)
    if isnothing(curr_id) || isnothing(preview_dir) || !isdir(preview_dir) || curr_id != preview_id
        return HTTP.Response(404, "Preview not found or expired.")
    end
    page_num = tryparse(Int, page)
    if isnothing(page_num) || page_num < 1
        return HTTP.Response(400, "Invalid page number.")
    end
    page_file = joinpath(preview_dir, "page-$page_num.png")
    if !isfile(page_file)
        return HTTP.Response(404, "Page $page_num not found.")
    end
    return HTTP.Response(200, [
        "Content-Type" => "image/png",
        "Cache-Control" => "no-store, no-cache, must-revalidate",
        "Pragma" => "no-cache",
    ], read(page_file))
end

@post "/api/preview_question" function(req::HTTP.Request)
    data = Oxygen.json(req)
    haskey(data, "question") || return Dict("status" => "error", "message" => "Missing question payload.")

    question_raw = _normalize_json_types(data["question"])
    if !isa(question_raw, AbstractDict)
        return Dict("status" => "error", "message" => "Question must be a JSON object.")
    end
    question = Dict{String, Any}(string(k) => v for (k, v) in pairs(question_raw))
    if !haskey(question, "type") || !haskey(question, "body")
        return Dict("status" => "error", "message" => "Question needs `type` and `body`.")
    end

    global_vars = get(data, "global_vars", nothing)
    if !isnothing(global_vars) && !isa(global_vars, AbstractString)
        return Dict("status" => "error", "message" => "`global_vars` must be a string or null.")
    end
    global_vars_str = isa(global_vars, AbstractString) ? String(global_vars) : ""

    margin = get(data, "margin", 1.5)
    if !(isa(margin, Number) && isfinite(Float64(margin)))
        return Dict("status" => "error", "message" => "`margin` must be a number.")
    end
    seed = get(data, "seed", 1234)
    if !(isa(seed, Integer) && seed > 0)
        seed = 1234
    end
    is_key = Bool(get(data, "is_key", true))

    selection = try
        preview_selection_for_question(question; seed=Int64(seed))
    catch e
        return Dict("status" => "error", "message" => "Could not sample question variables:\n$(sprint(showerror, e))")
    end

    preview_payload = Dict{String, Any}(
        "question" => question,
        "selection" => selection,
        "global_vars" => isempty(strip(global_vars_str)) ? nothing : global_vars_str,
        "margin" => Float64(margin),
        "is_key" => is_key,
    )
    payload_hash = _json_cache_key(preview_payload)

    return lock(PREVIEW_COMPILE_LOCK) do
        preview_dir, preview_id, work_dir = _ensure_builder_preview_dir!(; source_path=get(data, "source_path", nothing))
        svg_path = joinpath(preview_dir, "question.svg")
        if get(STATE, "question_preview_hash", nothing) == payload_hash && isfile(svg_path)
            return Dict(
                "status" => "success",
                "preview_id" => preview_id,
                "hash" => payload_hash,
                "cached" => true,
            )
        end

        preview_json = joinpath(preview_dir, "preview.json")
        open(preview_json, "w") do f
            json_print(f, preview_payload)
        end

        tmp_svg = joinpath(preview_dir, "question.tmp.svg")
        isfile(tmp_svg) && rm(tmp_svg; force=true)
        isdir(tmp_svg) && rm(tmp_svg; force=true, recursive=true)

        stderr_buf = IOBuffer()
        stdout_buf = IOBuffer()
        try
            typst_compile_question_preview(;
                preview_json=preview_json,
                output_svg=tmp_svg,
                work_dir=work_dir,
                stdout_io=stdout_buf,
                stderr_io=stderr_buf,
            )
            if !isfile(tmp_svg)
                return Dict("status" => "error", "message" => "Typst did not write a question SVG.")
            end
            mv(tmp_svg, svg_path; force=true)
            STATE["question_preview_hash"] = payload_hash
            return Dict(
                "status" => "success",
                "preview_id" => preview_id,
                "hash" => payload_hash,
                "cached" => false,
            )
        catch e
            isfile(tmp_svg) && rm(tmp_svg; force=true)
            isdir(tmp_svg) && rm(tmp_svg; force=true, recursive=true)
            err_details = String(take!(stderr_buf))
            msg = if !isempty(strip(err_details))
                strip(err_details)
            else
                sprint(showerror, e)
            end
            return Dict("status" => "error", "message" => "Question preview failed:\n" * msg)
        end
    end
end

@get "/api/preview_question/{preview_id}" function(req::HTTP.Request, preview_id::String)
    curr_id = get(STATE, "preview_id", nothing)
    preview_dir = get(STATE, "preview_dir", nothing)
    if isnothing(curr_id) || isnothing(preview_dir) || !isdir(preview_dir) || curr_id != preview_id
        return HTTP.Response(404, "Preview not found or expired.")
    end
    svg_file = joinpath(preview_dir, "question.svg")
    if !isfile(svg_file)
        return HTTP.Response(404, "Question preview not found.")
    end
    return HTTP.Response(200, [
        "Content-Type" => "image/svg+xml",
        "Cache-Control" => "no-store, no-cache, must-revalidate",
        "Pragma" => "no-cache",
    ], read(svg_file))
end

@post "/api/save_master_json" function(req::HTTP.Request)
    data = Oxygen.json(req)
    raw_path = string(get(data, "path", ""))
    if isempty(strip(raw_path))
        return Dict("status" => "error", "message" => "File path cannot be empty.")
    end
    if !endswith(lowercase(raw_path), ".json")
        raw_path = raw_path * ".json"
    end
    target_path = try
        resolve_under_workspace(raw_path)
    catch e
        return Dict("status" => "error", "message" => "Invalid save path: $(sprint(showerror, e))")
    end

    master_dict = _normalize_json_types(get(data, "master", Dict()))
    if !isa(master_dict, AbstractDict) && !isa(master_dict, Dict)
        return Dict("status" => "error", "message" => "Master JSON must be an object.")
    end
    master_data = Dict{String, Any}(string(k) => v for (k, v) in pairs(master_dict))
    try
        validate_master_json(master_data)
    catch e
        msg = sprint(showerror, e)
        msg = replace(msg, r"^ArgumentError:\s*" => "")
        return Dict("status" => "error", "message" => "Validation failed: $msg")
    end

    try
        mkpath(dirname(target_path))
        open(target_path, "w") do f
            json_print(f, master_data, 2)
        end
        return Dict("status" => "success", "path" => target_path, "display_path" => raw_path)
    catch e
        return Dict("status" => "error", "message" => "Failed to write file: $(sprint(showerror, e))")
    end
end

@post "/api/load_master_json" function(req::HTTP.Request)
    data = Oxygen.json(req)
    raw_path = string(get(data, "path", ""))
    if isempty(strip(raw_path))
        return Dict("status" => "error", "message" => "File path cannot be empty.")
    end
    target_path = try
        resolve_under_workspace(raw_path)
    catch
        raw_path
    end
    if !isfile(target_path)
        return Dict("status" => "error", "message" => "File not found: $raw_path")
    end
    try
        master_dict = validate_master_json_file(target_path)
        return Dict("status" => "success", "master" => master_dict, "path" => raw_path)
    catch e
        msg = sprint(showerror, e)
        msg = replace(msg, r"^ArgumentError:\s*" => "")
        return Dict("status" => "error", "message" => msg)
    end
end

@get "/api/download_log" function(req::HTTP.Request)
    log_file = joinpath(config_dir(), "biscuit.log")
    if !isfile(log_file)
        return HTTP.Response(404, [
            "Content-Type" => "text/plain; charset=utf-8",
        ], "Log file not found at $log_file")
    end
    try
        content = read(log_file)
        headers = [
            "Content-Type" => "text/plain; charset=utf-8",
            "Content-Disposition" => "attachment; filename=\"biscuit.log\"",
            "Cache-Control" => "no-cache",
        ]
        return HTTP.Response(200, headers, content)
    catch e
        return HTTP.Response(500, [
            "Content-Type" => "text/plain; charset=utf-8",
        ], "Failed to read log file: $(sprint(showerror, e))")
    end
end

staticfiles(joinpath(package_root(), "public"), "/")

# Oxygen maps public/index.html to an empty route when mounted at "/", which does not
# match GET /. Register the homepage explicitly.
@get "/" function()
    file(joinpath(package_root(), "public", "index.html"))
end

    _ROUTES_REGISTERED[] = true
    return
end
