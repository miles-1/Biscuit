function _register_routes!()
    _ROUTES_REGISTERED[] && return

@websocket "/api/ws_generate" function(ws)
    for msg in ws
        data = JSON.parse(String(msg))
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
        data = JSON.parse(String(msg))
        tiff_file = data["tiff_file"]
        assn_versions_file = data["assn_file"]
        corrections = get(data, "corrections", Dict{String, Any}())
        
        if !isfile(tiff_file)
            throw(ArgumentError("`tiff_file` was provided but could not be found: $tiff_file"))
        elseif !isfile(assn_versions_file)
            throw(ArgumentError("`assn_versions_file` was provided but could not be found: $assn_versions_file"))
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
            process_scans(
                tiff_file;
                assn_versions_file=assn_versions_file,
                corrections=corrections,
                namereader_file=_optional_path(get(data, "namereader_file", nothing)),
                output_name=_optional_path(get(data, "new_file_name", nothing)),
            )
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
            data = JSON.parse(String(msg))
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
                    handwriting_dir = _optional_path(get(data, "handwriting_dir", nothing))
                    background_dir = _optional_path(get(data, "background_dir", nothing))
                    if handwriting_dir === nothing || !isdir(handwriting_dir)
                        throw(ArgumentError("handwriting_dir must be an existing folder of per-student name crops"))
                    end
                    output_name = _optional_path(get(data, "new_file_name", nothing))
                    stem = if output_name !== nothing
                        first(splitext(basename(output_name)))
                    else
                        NameReader.class_stem_from_training_dir(handwriting_dir)
                    end
                    dest = joinpath(dirname(abspath(handwriting_dir)), stem * ".namereader")
                    bg = background_dir === nothing ? NameReader.background_training_dir() : background_dir
                    println("Training NameReader")
                    println("  handwriting: ", handwriting_dir)
                    println("  backgrounds: ", bg)
                    println("  output: ", dest)
                    train_name_reader(
                        handwriting_dir;
                        background_dir=bg,
                        output_path=dest,
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
    return Dict("status" => "success", "grading_data" => grading_data)
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
            JSON.print(f, grading_data)
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

# --- Managed classes (roster CSVs) ---

@get "/api/classes" function(req::HTTP.Request)
    try
        return Dict("status" => "success", "classes" => list_classes())
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

# Crop mapped name boxes from annotated scans into [class]_name_training_data next to the .assn.
@post "/api/export_name_training_data" function(req::HTTP.Request)
    temp_dir = STATE["temp_archive_dir"]
    archive_path = STATE["assn_archive_path"]
    if isnothing(temp_dir) || isnothing(archive_path)
        return Dict("status" => "error", "message" => "No archive loaded")
    end
    processed_file = joinpath(temp_dir, "processed_assn_data.json")
    grading_data_file = joinpath(temp_dir, "grading_data.json")
    annotated_scan_folder = joinpath(temp_dir, "annotated")
    if !isfile(processed_file)
        return Dict("status" => "error", "message" => "Missing processed_assn_data.json.")
    end
    if !isfile(grading_data_file)
        return Dict("status" => "error", "message" => "Missing grading_data.json; save grading work first.")
    end
    if !isdir(annotated_scan_folder)
        return Dict("status" => "error", "message" => "Missing annotated scans folder.")
    end
    class_name = nothing
    try
        roster = _read_roster_from_temp(; give_default=true)
        if roster !== nothing
            class_name = roster.class_name
        end
    catch
        # Fall back to archive stem inside export_name_training_data.
    end
    try
        output_dir = export_name_training_data(;
            processed_assn_data_file=processed_file,
            grading_data_file=grading_data_file,
            annotated_scan_folder=annotated_scan_folder,
            archive_path=String(archive_path),
            class_name=class_name,
        )
        return Dict(
            "status" => "success",
            "output_dir" => output_dir,
            "exported" => output_dir !== nothing,
        )
    catch e
        return Dict("status" => "error", "message" => "Failed to export name training data: $e")
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
    elseif !has_student_email
        push!(missing, "Class roster CSV is missing an `Email` column.")
    end
    return Dict(
        "status" => "success",
        "linked" => linked,
        "needs_authorization" => client_ok && !linked,
        "client_available" => client_ok,
        "has_student_email" => has_student_email,
        "roster_present" => roster_present,
        "class_name" => class_name,
        "can_upload" => client_ok && roster_present && has_student_email,
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
    if !students_table_has_email(students)
        return Dict(
            "status" => "error",
            "message" => "Class roster CSV must include an `Email` column for Google Drive upload",
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
        data = JSON.parse(String(msg))
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
            println("SUMMARY:" * JSON.json(Dict(
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
            parsed = JSON.parse(string(data["json_string"]))
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

@post "/api/preview_master_json" function(req::HTTP.Request)
    data = Oxygen.json(req)
    master_dict = if haskey(data, "master")
        _normalize_json_types(data["master"])
    elseif haskey(data, "json_string")
        try
            JSON.parse(string(data["json_string"]))
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

    # Clean up previous preview directory
    prev_preview = get(STATE, "preview_dir", nothing)
    if isa(prev_preview, AbstractString) && isdir(prev_preview)
        try
            rm(prev_preview; force=true, recursive=true)
        catch
        end
    end

    # Create app-managed preview directory inside the workspace root to conform with Typst sandbox
    workspace_root = try
        resolve_under_workspace(".")
    catch
        pwd()
    end
    preview_dir = mktempdir(workspace_root)
    STATE["preview_dir"] = preview_dir
    preview_id = string(rand(UInt64), base=16)
    STATE["preview_id"] = preview_id

    master_file_path = joinpath(preview_dir, "master.json")
    open(master_file_path, "w") do f
        JSON.print(f, master_data)
    end

    stderr_buf = IOBuffer()
    stdout_buf = IOBuffer()
    try
        selection_file = GenerateAssnFiles.generate_selection_json(;
            master_file=master_file_path,
            output_dir=preview_dir,
        )

        master_rel = replace(relpath(master_file_path), "\\" => "/")
        selection_rel = replace(relpath(selection_file), "\\" => "/")
        source_file = Commands.assn_typst_file()
        out_pattern = joinpath(preview_dir, "page-{p}.png")
        will_print_double_sided = Bool(get(master_data, "will_print_double_sided", true))

        args = [
            "compile",
            "--input", "master=$master_rel",
            "--input", "selection=$selection_rel",
            "--input", "single_doc_export=true",
            "--input", "will_print_double_sided=$will_print_double_sided",
            "--ppi", "144",
            "-",
            out_pattern,
        ]

        cmd = pipeline(`typst $args`, stdin=source_file, stdout=stdout_buf, stderr=stderr_buf)
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
            JSON.print(f, master_data, 2)
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
