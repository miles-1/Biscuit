module GoogleDrive

using HTTP
using JSON
using CSV
using Random
using Sockets

using ..Paths: package_root, config_dir
using ..Classes: roster_has_email

export google_drive_credentials_linked
export google_drive_client_available
export google_drive_client_path
export google_drive_token_path
export sanitize_student_name
export display_student_name
export students_table_has_email
export authorize_google_drive
export process_and_upload_pdf
export preview_drive_upload_conflicts
export upload_feedback_pdfs

# Master JSON `assn_type` values, mapped to Drive folder names.
const ASSN_TYPES = Set(["quiz", "worksheet", "exam"])
const ASSN_TYPE_TO_FOLDER = Dict(
    "quiz" => "quizzes",
    "worksheet" => "worksheets",
    "exam" => "exams",
)
const GOOGLE_DRIVE_OAUTH_SCOPE = "https://www.googleapis.com/auth/drive"
const GOOGLE_OAUTH_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
const GOOGLE_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
# Shipped with the app (OAuth client identity). Not a per-user secret.
function google_drive_client_path()::String
    return joinpath(package_root(), "google_drive_client.json")
end

"""
Per-user token file managed by the app (not browsed by the user).
"""
function google_drive_token_path()::String
    return joinpath(config_dir(), "google_drive_token.json")
end

function google_drive_client_available()::Bool
    return isfile(google_drive_client_path())
end

function google_drive_credentials_linked(token_path::Union{AbstractString, Nothing}=nothing)::Bool
    path = token_path === nothing ? google_drive_token_path() : token_path
    return isa(path, AbstractString) && !isempty(strip(path)) && isfile(path)
end

function drive_folder_for_assn_type(assn_type::AbstractString)::String
    folder = get(ASSN_TYPE_TO_FOLDER, String(assn_type), nothing)
    folder === nothing && throw(ArgumentError(
        "assn_type must be one of $(join(sort(collect(ASSN_TYPES)), ", ")); got $(repr(assn_type))"
    ))
    return folder
end

"""
Sanitize a roster name the same way feedback.typ names per-student PDFs.
"""
function sanitize_student_name(name::AbstractString)::String
    return lowercase(replace(String(name), ", " => "_"))
end

"""
Convert a roster name (`Last, First`) to display order (`First Last`).
"""
function display_student_name(name::AbstractString)::String
    parts = split(String(name), ','; limit=2)
    if length(parts) == 2
        return strip(parts[2]) * " " * strip(parts[1])
    end
    return strip(String(name))
end

function students_table_has_email(students_table)::Bool
    return roster_has_email(students_table)
end

function _cell_string(value)::Union{String, Nothing}
    if ismissing(value) || value === nothing
        return nothing
    end
    # CSV.jl often yields InlineString (e.g. String31); normalize to Base.String.
    s = strip(String(value))
    return isempty(s) ? nothing : s
end

"""
Escape a value for use inside a single-quoted Google Drive `q` string.
"""
function _drive_q_escape(s::AbstractString)::String
    return replace(String(s), "'" => "\\'")
end

"""
Parse a Google Cloud OAuth client secrets JSON (`installed` / `web` wrapper, or flat).
"""
function parse_oauth_client_file(client_secrets_path::AbstractString)
    isfile(client_secrets_path) || throw(ArgumentError(
        "OAuth client secrets file not found: $client_secrets_path"
    ))
    data = JSON.parse(read(client_secrets_path, String))
    client_type = if haskey(data, "installed")
        "installed"
    elseif haskey(data, "web")
        "web"
    elseif haskey(data, "client_id")
        "flat"
    else
        throw(ArgumentError(
            "Unrecognized OAuth client secrets JSON at $(repr(client_secrets_path)). " *
            "Expected an `installed` or `web` object from Google Cloud."
        ))
    end
    client = client_type == "flat" ? data : data[client_type]
    client_id = string(get(client, "client_id", ""))
    client_secret = string(get(client, "client_secret", ""))
    isempty(client_id) && throw(ArgumentError("OAuth client secrets JSON is missing client_id."))
    isempty(client_secret) && throw(ArgumentError("OAuth client secrets JSON is missing client_secret."))
    return (client_id=client_id, client_secret=client_secret, client_type=client_type)
end

function _open_system_browser(url::AbstractString)
    if Sys.isapple()
        run(`open $url`)
    elseif Sys.iswindows()
        run(`cmd /c start "" $url`)
    else
        run(`xdg-open $url`)
    end
    return nothing
end

function _free_loopback_port()::Int
    server = Sockets.listen(Sockets.InetAddr(ip"127.0.0.1", 0))
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    return port
end

"""
Run the Google OAuth desktop (loopback) flow for Drive access.

Uses the shipped client at `google_drive_client.json` and writes the per-user token to
`~/.config/biscuit/google_drive_token.json` by default. Opens the system browser, waits for
consent, then returns the written token path.
"""
function authorize_google_drive(
    client_secrets_path::AbstractString=google_drive_client_path();
    output_path::Union{AbstractString, Nothing}=nothing,
    scope::AbstractString=GOOGLE_DRIVE_OAUTH_SCOPE,
    timeout_seconds::Real=300,
)::String
    client = parse_oauth_client_file(client_secrets_path)
    if client.client_type == "web"
        @warn "Using a Web OAuth client for the desktop loopback flow. Prefer a Desktop client, or add http://127.0.0.1:<port>/ as an authorized redirect URI if authorization fails."
    end

    out = if output_path === nothing || isempty(strip(String(output_path)))
        google_drive_token_path()
    else
        String(output_path)
    end

    port = _free_loopback_port()
    redirect_uri = "http://127.0.0.1:$port/"
    state = randstring(24)
    result_ch = Channel{Any}(1)

    # stream=true so we own the HTTP.Stream for the OAuth redirect response body.
    server = HTTP.serve!("127.0.0.1", port; stream=true, verbose=false) do http::HTTP.Stream
        req = http.message
        target = HTTP.URI(req.target)
        params = HTTP.URIs.queryparams(target)
        try
            if get(params, "state", "") != state
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "text/html; charset=utf-8")
                HTTP.startwrite(http)
                write(http, "<html><body><h2>Authorization failed</h2><p>Invalid OAuth state.</p></body></html>")
                put!(result_ch, ErrorException("OAuth state mismatch; try Authorize again."))
                return
            end
            if haskey(params, "error")
                err = string(params["error"])
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "text/html; charset=utf-8")
                HTTP.startwrite(http)
                write(http, "<html><body><h2>Authorization denied</h2><p>$(HTTP.escapehtml(err))</p></body></html>")
                put!(result_ch, ErrorException("Google OAuth error: $err"))
                return
            end
            code = string(get(params, "code", ""))
            if isempty(code)
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "text/html; charset=utf-8")
                HTTP.startwrite(http)
                write(http, "<html><body><h2>Authorization failed</h2><p>Missing authorization code.</p></body></html>")
                put!(result_ch, ErrorException("OAuth redirect did not include an authorization code."))
                return
            end
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/html; charset=utf-8")
            HTTP.startwrite(http)
            write(http, "<html><body><h2>Google Drive linked</h2><p>You can close this tab and return to Biscuit.</p></body></html>")
            put!(result_ch, code)
        catch e
            put!(result_ch, e)
        end
    end

    auth_url = string(HTTP.URI(
        GOOGLE_OAUTH_AUTH_URL;
        query=Dict(
            "client_id" => client.client_id,
            "redirect_uri" => redirect_uri,
            "response_type" => "code",
            "scope" => String(scope),
            "access_type" => "offline",
            "prompt" => "consent",
            "state" => state,
        ),
    ))

    timeout_timer = Timer(Float64(timeout_seconds)) do _
        if !isready(result_ch)
            try
                put!(result_ch, ErrorException(
                    "Timed out waiting for Google authorization ($(timeout_seconds)s)."
                ))
            catch
            end
        end
    end

    try
        println("Opening browser for Google Drive authorization…")
        println("If it does not open, visit:\n$auth_url")
        try
            _open_system_browser(auth_url)
        catch e
            @warn "Could not open a browser automatically; open the URL printed above." exception=e
        end

        code_or_err = take!(result_ch)
        isa(code_or_err, Exception) && throw(code_or_err)
        code = String(code_or_err)

        body = HTTP.URIs.escapeuri(Dict(
            "code" => code,
            "client_id" => client.client_id,
            "client_secret" => client.client_secret,
            "redirect_uri" => redirect_uri,
            "grant_type" => "authorization_code",
        ))
        resp = HTTP.post(
            GOOGLE_OAUTH_TOKEN_URL,
            ["Content-Type" => "application/x-www-form-urlencoded"],
            body;
            status_exception=false,
        )
        res_json = try
            JSON.parse(String(resp.body))
        catch
            Dict{String, Any}("error" => "non-JSON token response", "error_description" => String(resp.body))
        end
        if resp.status >= 300 || !haskey(res_json, "access_token")
            err = string(get(res_json, "error", "unknown_error"))
            desc = string(get(res_json, "error_description", ""))
            detail = isempty(desc) ? err : "$err: $desc"
            throw(ErrorException("Google OAuth token exchange failed (HTTP $(resp.status)): $detail"))
        end
        if !haskey(res_json, "refresh_token")
            throw(ErrorException(
                "Google did not return a refresh_token. Revoke this app under your Google Account " *
                "third-party access, then Authorize again."
            ))
        end

        token_out = Dict{String, Any}(
            "access_token" => res_json["access_token"],
            "refresh_token" => res_json["refresh_token"],
            "client_id" => client.client_id,
            "client_secret" => client.client_secret,
            "token_type" => get(res_json, "token_type", "Bearer"),
            "scope" => get(res_json, "scope", String(scope)),
            "expires_in" => get(res_json, "expires_in", nothing),
        )
        out_dir = dirname(out)
        !isempty(out_dir) && mkpath(out_dir)
        open(out, "w") do io
            JSON.print(io, token_out, 2)
        end
        println("Wrote Google Drive token file: $out")
        return abspath(out)
    finally
        close(timeout_timer)
        try close(server) catch end
        close(result_ch)
    end
end

"""
Reads token.json and refreshes the access token if needed.
"""
function get_access_token(token_path::String)::String
    token_data = JSON.parse(read(token_path, String))

    if haskey(token_data, "refresh_token") && haskey(token_data, "client_id")
        # Google's token endpoint expects form-urlencoded, not JSON.
        body = HTTP.URIs.escapeuri(Dict(
            "client_id" => string(token_data["client_id"]),
            "client_secret" => string(get(token_data, "client_secret", "")),
            "refresh_token" => string(token_data["refresh_token"]),
            "grant_type" => "refresh_token",
        ))
        resp = HTTP.post(
            GOOGLE_OAUTH_TOKEN_URL,
            ["Content-Type" => "application/x-www-form-urlencoded"],
            body;
            status_exception=false,
        )
        res_json = try
            JSON.parse(String(resp.body))
        catch
            Dict{String, Any}("error" => "non-JSON token response", "error_description" => String(resp.body))
        end
        if resp.status >= 300 || !haskey(res_json, "access_token")
            err = string(get(res_json, "error", "unknown_error"))
            desc = string(get(res_json, "error_description", ""))
            detail = isempty(desc) ? err : "$err: $desc"
            throw(ErrorException(
                "Google OAuth token refresh failed (HTTP $(resp.status)): $detail. " *
                "Re-run Authorize Google Drive for this OAuth client."
            ))
        end
        return String(res_json["access_token"])
    elseif haskey(token_data, "access_token")
        return String(token_data["access_token"])
    else
        hint = if haskey(token_data, "installed") || haskey(token_data, "web")
            " This looks like an OAuth *client* secrets file from Google Cloud (installed/web). " *
            "Use Authorize Google Drive to create a token file, or pick an existing token JSON."
        else
            " Expected top-level keys refresh_token + client_id (+ client_secret), or access_token."
        end
        throw(ErrorException(
            "Credentials JSON at $(repr(token_path)) is not a usable token file.$hint"
        ))
    end
end

"""
Shares a folder or file with a specific email address.
`role` can be "reader", "commenter", or "writer".
"""
function share_item(
    headers::Vector{Pair{String, String}},
    file_or_folder_id::String,
    target_email::String;
    role::String="reader",
    send_email::Bool=true,
)
    url = "https://www.googleapis.com/drive/v3/files/$(file_or_folder_id)/permissions?sendNotificationEmail=$(send_email)&supportsAllDrives=true"
    body = Dict(
        "role" => role,
        "type" => "user",
        "emailAddress" => target_email,
    )
    post_headers = vcat(headers, ["Content-Type" => "application/json"])
    resp = HTTP.post(url, post_headers, JSON.json(body))
    return JSON.parse(String(resp.body))
end

const _DRIVE_LIST_EXTRAS = Dict(
    "supportsAllDrives" => "true",
    "includeItemsFromAllDrives" => "true",
    "spaces" => "drive",
)

function _drive_list(headers, query::Dict)
    return HTTP.get(
        "https://www.googleapis.com/drive/v3/files",
        headers,
        query=merge(Dict{String, String}("fields" => "files(id, name)"), _DRIVE_LIST_EXTRAS, Dict{String, String}(string(k) => string(v) for (k, v) in query)),
    )
end

"""
Checks if a folder exists by name (and optional parent ID).
"""
function get_folder_id(
    headers::Vector{Pair{String, String}},
    folder_name::String;
    parent_id::Union{String, Nothing}=nothing,
)::Union{String, Nothing}
    q = "name = '$(_drive_q_escape(folder_name))' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    if !isnothing(parent_id)
        q *= " and '$(parent_id)' in parents"
    end
    resp = _drive_list(headers, Dict("q" => q))
    files = JSON.parse(String(resp.body))["files"]
    if !isempty(files)
        return String(files[1]["id"])
    end
    return nothing
end

"""
Creates a new Google Drive folder.
"""
function create_folder(
    headers::Vector{Pair{String, String}},
    folder_name::String;
    parent_id::Union{String, Nothing}=nothing,
)::String
    url = "https://www.googleapis.com/drive/v3/files?supportsAllDrives=true"
    body_dict = Dict{String, Any}(
        "name" => folder_name,
        "mimeType" => "application/vnd.google-apps.folder",
    )
    if !isnothing(parent_id)
        body_dict["parents"] = [parent_id]
    end
    post_headers = vcat(headers, ["Content-Type" => "application/json"])
    resp = HTTP.post(url, post_headers, JSON.json(body_dict))
    return String(JSON.parse(String(resp.body))["id"])
end

"""
Find-or-create a folder. Returns `(id, created)`.
"""
function ensure_folder(
    headers::Vector{Pair{String, String}},
    folder_name::String;
    parent_id::Union{String, Nothing}=nothing,
)::Tuple{String, Bool}
    existing = get_folder_id(headers, folder_name; parent_id=parent_id)
    if !isnothing(existing)
        return (existing, false)
    end
    return (create_folder(headers, folder_name; parent_id=parent_id), true)
end

function student_feedback_folder_name(class_name::AbstractString, student_roster_name::AbstractString)::String
    return "$(strip(String(class_name))) Assignment Feedback - $(display_student_name(student_roster_name))"
end

function find_file_in_folder(
    headers::Vector{Pair{String, String}},
    parent_folder_id::String,
    filename::String,
)::Union{NamedTuple{(:id, :name), Tuple{String, String}}, Nothing}
    q = "name = '$(_drive_q_escape(filename))' and '$(parent_folder_id)' in parents and trashed = false"
    resp = _drive_list(headers, Dict("q" => q, "fields" => "files(id, name)"))
    files = JSON.parse(String(resp.body))["files"]
    isempty(files) && return nothing
    f = files[1]
    return (id=String(f["id"]), name=String(f["name"]))
end

function list_filenames_in_folder(
    headers::Vector{Pair{String, String}},
    parent_folder_id::String,
)::Vector{String}
    q = "'$(parent_folder_id)' in parents and trashed = false"
    resp = _drive_list(headers, Dict("q" => q, "fields" => "files(name)"))
    return [String(f["name"]) for f in JSON.parse(String(resp.body))["files"]]
end

function delete_drive_file(headers::Vector{Pair{String, String}}, file_id::String)
    HTTP.delete(
        "https://www.googleapis.com/drive/v3/files/$(file_id)?supportsAllDrives=true",
        headers;
        status_exception=false,
    )
    return nothing
end

"""
Checks existing files in the folder and appends (1), (2), etc. if the target filename exists.
"""
function get_unique_filename(
    headers::Vector{Pair{String, String}},
    parent_folder_id::String,
    base_filename::String,
)::String
    existing_files = list_filenames_in_folder(headers, parent_folder_id)
    if !(base_filename in existing_files)
        return base_filename
    end
    name_part, ext_part = splitext(base_filename)
    counter = 1
    while true
        new_name = "$(name_part) ($(counter))$(ext_part)"
        if !(new_name in existing_files)
            return new_name
        end
        counter += 1
    end
end

"""
Uploads a file to Google Drive using multipart upload.
"""
function upload_pdf(
    headers::Vector{Pair{String, String}},
    local_file_path::String,
    target_filename::String,
    parent_folder_id::String,
)::String
    url = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true"
    boundary = "================JuliaDriveUploadBoundary=="

    file_bytes = read(local_file_path)
    metadata_json = JSON.json(Dict("name" => target_filename, "parents" => [parent_folder_id]))

    body = IOBuffer()
    write(body, "--$boundary\r\n")
    write(body, "Content-Type: application/json; charset=UTF-8\r\n\r\n")
    write(body, metadata_json)
    write(body, "\r\n--$boundary\r\n")
    write(body, "Content-Type: application/pdf\r\n\r\n")
    write(body, file_bytes)
    write(body, "\r\n--$boundary--\r\n")

    upload_headers = vcat(headers, ["Content-Type" => "multipart/related; boundary=$boundary"])
    resp = HTTP.post(url, upload_headers, take!(body))

    uploaded_file = JSON.parse(String(resp.body))
    return String(uploaded_file["id"])
end

"""
Look up roster name + email by matching a sanitized PDF stem against roster CSV names.
Requires an `Email` column.

Returns a NamedTuple with `status` one of:
- `:ok` — `name` and `email` set
- `:no_email` — name matched but `Email` empty; `name` set
- `:no_match` — no roster name matched the PDF stem
"""
function find_student_for_pdf_stem(students_table, pdf_stem::String)
    if !students_table_has_email(students_table) || !haskey(students_table, :Student)
        return (status=:no_match, name=nothing, email=nothing)
    end
    for (name, email) in zip(students_table.Student, students_table.Email)
        name_str = String(name)
        if sanitize_student_name(name_str) == pdf_stem
            email_str = _cell_string(email)
            if email_str === nothing
                return (status=:no_email, name=name_str, email=nothing)
            end
            return (status=:ok, name=name_str, email=email_str)
        end
    end
    return (status=:no_match, name=nothing, email=nothing)
end

"""
Ensure `Biscuit / class_name` exists. Returns the class folder id.
"""
function ensure_class_root(
    headers::Vector{Pair{String, String}},
    class_name::AbstractString,
)::String
    biscuit_id, biscuit_created = ensure_folder(headers, "Biscuit")
    if biscuit_created
        println("Created folder: Biscuit")
    end
    class_id, class_created = ensure_folder(headers, String(class_name); parent_id=biscuit_id)
    if class_created
        println("Created folder: Biscuit / $(strip(String(class_name)))")
    end
    return class_id
end

"""
Resolve (or create) the type subfolder for one student under the class root.
Shares the student folder only when newly created.
Returns the quizzes|worksheets|exams folder id.
"""
function ensure_student_type_folder(
    headers::Vector{Pair{String, String}},
    class_folder_id::String,
    class_name::AbstractString,
    student_roster_name::AbstractString,
    recipient_email::AbstractString,
    assn_type::AbstractString,
)::String
    type_folder = drive_folder_for_assn_type(assn_type)
    student_folder = student_feedback_folder_name(class_name, student_roster_name)
    student_id, student_created = ensure_folder(headers, student_folder; parent_id=class_folder_id)
    if student_created
        println("Created folder: $student_folder")
        share_item(headers, student_id, recipient_email, role="reader")
        println("Shared folder $student_folder with $recipient_email")
    end
    type_id, type_created = ensure_folder(headers, type_folder; parent_id=student_id)
    if type_created
        println("Created subfolder: $student_folder / $type_folder")
    end
    return type_id
end

function target_pdf_filename(assn_name::AbstractString)::String
    return endswith(assn_name, ".pdf") ? String(assn_name) : "$(assn_name).pdf"
end

const DUPLICATE_POLICIES = Set(["replace", "skip", "add_new"])

function normalize_duplicate_policy(policy::AbstractString)::String
    p = String(policy)
    p in DUPLICATE_POLICIES || throw(ArgumentError(
        "duplicate_policy must be one of $(join(sort(collect(DUPLICATE_POLICIES)), ", ")); got $(repr(policy))"
    ))
    return p
end

"""
Upload one local PDF into
`Biscuit / class_name / [class_name] Assignment Feedback - [Display Name] / quizzes|worksheets|exams / assn.pdf`.
"""
function process_and_upload_pdf(
    headers::Vector{Pair{String, String}},
    class_folder_id::String,
    class_name::AbstractString,
    local_file_path::AbstractString,
    assn_type::AbstractString,
    assn_name::AbstractString,
    recipient_email::AbstractString,
    student_roster_name::AbstractString,
    duplicate_policy::AbstractString,
)::Union{String, Nothing}
    policy = normalize_duplicate_policy(duplicate_policy)
    type_folder_id = ensure_student_type_folder(
        headers,
        class_folder_id,
        class_name,
        student_roster_name,
        recipient_email,
        assn_type,
    )
    target_filename = target_pdf_filename(assn_name)
    existing = find_file_in_folder(headers, type_folder_id, target_filename)

    if !isnothing(existing)
        if policy == "skip"
            println("Skipped existing file: $target_filename")
            return nothing
        elseif policy == "replace"
            delete_drive_file(headers, existing.id)
            println("Replacing existing file: $target_filename")
            final_filename = target_filename
        else  # add_new
            final_filename = get_unique_filename(headers, type_folder_id, target_filename)
            println("Uploading as new copy: $final_filename")
        end
    else
        final_filename = target_filename
    end

    uploaded_id = upload_pdf(headers, String(local_file_path), final_filename, type_folder_id)
    println("Successfully uploaded: $final_filename (ID: $uploaded_id)")
    return uploaded_id
end

"""
Return PDF uploads that would collide with an existing Drive file of the same assignment name.
Creates only the top-level `Biscuit / class_name` folders if missing; does not create student folders.
"""
function preview_drive_upload_conflicts(
    token_path::String,
    feedback_dir::String,
    students_table,
    assn_type::String,
    assn_name::String,
    class_name::String,
)::Dict{String, Any}
    type_folder = drive_folder_for_assn_type(assn_type)
    isdir(feedback_dir) || throw(ArgumentError("feedback directory not found: $feedback_dir"))
    google_drive_credentials_linked(token_path) ||
        throw(ArgumentError("Google Drive credentials file not found: $token_path"))
    students_table_has_email(students_table) ||
        throw(ArgumentError("Class roster CSV must include an `Email` column for Google Drive upload"))
    isempty(strip(class_name)) && throw(ArgumentError("`class_name` is required for Google Drive upload"))

    access_token = get_access_token(token_path)
    headers = ["Authorization" => "Bearer $access_token"]
    class_folder_id = ensure_class_root(headers, class_name)
    target_filename = target_pdf_filename(assn_name)

    pdf_files = sort(filter(f -> endswith(lowercase(f), ".pdf"), readdir(feedback_dir)))
    conflicts = Any[]
    uploadable = 0
    skipped_no_email = 0

    for pdf_name in pdf_files
        pdf_stem = first(splitext(pdf_name))
        student = find_student_for_pdf_stem(students_table, pdf_stem)
        if student.status === :no_email
            skipped_no_email += 1
            continue
        elseif student.status === :no_match
            continue
        end
        uploadable += 1
        student_folder = student_feedback_folder_name(class_name, student.name)
        student_id = get_folder_id(headers, student_folder; parent_id=class_folder_id)
        isnothing(student_id) && continue
        type_id = get_folder_id(headers, type_folder; parent_id=student_id)
        isnothing(type_id) && continue
        existing = find_file_in_folder(headers, type_id, target_filename)
        if !isnothing(existing)
            push!(conflicts, Dict(
                "file" => pdf_name,
                "name" => student.name,
                "email" => student.email,
                "drive_filename" => target_filename,
                "folder" => student_folder,
            ))
        end
    end

    return Dict{String, Any}(
        "conflicts" => conflicts,
        "conflict_count" => length(conflicts),
        "uploadable_count" => uploadable,
        "skipped_no_email_count" => skipped_no_email,
        "target_filename" => target_filename,
        "class_name" => class_name,
        "assn_type" => assn_type,
        "assn_name" => assn_name,
    )
end

"""
Upload every PDF in `feedback_dir` to Google Drive under Biscuit / class_name / ...
`duplicate_policy` is `replace`, `skip`, or `add_new`.
"""
function upload_feedback_pdfs(
    token_path::String,
    feedback_dir::String,
    students_table,
    assn_type::String,
    assn_name::String,
    class_name::String;
    duplicate_policy::String="add_new",
)::Dict{String, Any}
    drive_folder_for_assn_type(assn_type)
    policy = normalize_duplicate_policy(duplicate_policy)
    isdir(feedback_dir) || throw(ArgumentError("feedback directory not found: $feedback_dir"))
    google_drive_credentials_linked(token_path) ||
        throw(ArgumentError("Google Drive credentials file not found: $token_path"))
    students_table_has_email(students_table) ||
        throw(ArgumentError("Class roster CSV must include an `Email` column for Google Drive upload"))
    isempty(strip(class_name)) && throw(ArgumentError("`class_name` is required for Google Drive upload"))

    access_token = get_access_token(token_path)
    headers = ["Authorization" => "Bearer $access_token"]
    class_folder_id = ensure_class_root(headers, class_name)

    pdf_files = sort(filter(f -> endswith(lowercase(f), ".pdf"), readdir(feedback_dir)))
    uploaded = Any[]
    skipped_no_email = Any[]
    skipped_duplicate = Any[]
    failed = Any[]

    for pdf_name in pdf_files
        local_path = joinpath(feedback_dir, pdf_name)
        pdf_stem = first(splitext(pdf_name))
        try
            student = find_student_for_pdf_stem(students_table, pdf_stem)
            if student.status === :no_email
                push!(skipped_no_email, Dict(
                    "file" => pdf_name,
                    "name" => student.name,
                ))
                continue
            elseif student.status === :no_match
                throw(ErrorException(
                    "No class roster row matches sanitized name $(repr(pdf_stem))"
                ))
            end
            file_id = process_and_upload_pdf(
                headers,
                class_folder_id,
                class_name,
                local_path,
                assn_type,
                assn_name,
                student.email,
                student.name,
                policy,
            )
            if file_id === nothing
                push!(skipped_duplicate, Dict(
                    "file" => pdf_name,
                    "name" => student.name,
                    "email" => student.email,
                ))
            else
                push!(uploaded, Dict(
                    "file" => pdf_name,
                    "name" => student.name,
                    "email" => student.email,
                    "drive_file_id" => file_id,
                ))
            end
        catch e
            push!(failed, Dict(
                "file" => pdf_name,
                "error" => sprint(showerror, e),
            ))
        end
    end

    return Dict{String, Any}(
        "uploaded" => uploaded,
        "skipped_no_email" => skipped_no_email,
        "skipped_duplicate" => skipped_duplicate,
        "failed" => failed,
        "total_pdfs" => length(pdf_files),
        "duplicate_policy" => policy,
        "class_name" => class_name,
    )
end

end # module
