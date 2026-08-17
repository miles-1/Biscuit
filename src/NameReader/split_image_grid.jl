using FileIO
using ImageIO
using JSON3
using Oxygen
using Random
using HTTP
import YAML

"""
    SplitGridResult

Metadata returned by `split_image_grid`.
"""
struct SplitGridResult
    image_path::String
    width::Int
    height::Int
    nrows::Int
    ncols::Int
    output_directory::String
    tile_paths::Vector{String}
    label_counts::Dict{String,Int}
    sidecar_path::Union{Nothing,String}
end

"""
    GridCell

The grid coordinates and pixel ranges for one image tile.
"""
struct GridCell
    row_index::Int
    col_index::Int
    row_range::UnitRange{Int}
    col_range::UnitRange{Int}
end

mutable struct ManualLabelRecord
    order_index::Int
    cell::GridCell
    label::String
    tile_path::String
end

mutable struct ManualLabelState
    image_path::String
    width::Int
    height::Int
    nrows::Int
    ncols::Int
    output_directory::String
    cells::Vector{GridCell}
    pending_paths::Vector{String}
    records::Vector{Union{Nothing,ManualLabelRecord}}
    current_index::Int
    label_counts::Dict{String,Int}
    label_next_indices::Dict{String,Int}
    review_return_index::Union{Nothing,Int}
    done::Bool
    done_channel::Channel{Bool}
    lock::ReentrantLock
end

"""
    image_dimensions(image_path) -> (width, height)

Load an image and return its width and height in pixels.
"""
function image_dimensions(image_path::AbstractString)
    img = load(image_path)
    height, width = size(img)[1:2]
    return width, height
end

function bounds_for_parts(total::Integer, nparts::Integer)
    nparts > 0 || throw(ArgumentError("number of parts must be positive"))
    return [
        floor(Int, (i - 1) * total / nparts) + 1:floor(Int, i * total / nparts)
        for i in 1:nparts
    ]
end

function grid_cells(height::Integer, width::Integer, nrows::Integer, ncols::Integer)
    row_ranges = bounds_for_parts(height, nrows)
    col_ranges = bounds_for_parts(width, ncols)
    return [
        GridCell(row_index, col_index, rows, cols)
        for (row_index, rows) in enumerate(row_ranges)
        for (col_index, cols) in enumerate(col_ranges)
    ]
end

"""
    output_directory(image_path, nrows, ncols)

Return the default output directory for an image split.
"""
function output_directory(image_path::AbstractString, nrows::Integer, ncols::Integer)
    base = splitext(basename(image_path))[1]
    return joinpath(dirname(image_path), base * "-" * string(nrows) * "x" * string(ncols))
end

function image_tile(img, rows, cols)
    trailing_axes = ntuple(_ -> Colon(), ndims(img) - 2)
    return img[rows, cols, trailing_axes...]
end

image_tile(img, cell::GridCell) = image_tile(img, cell.row_range, cell.col_range)

function sanitize_label(label)
    cleaned = replace(strip(String(label)), r"[^A-Za-z0-9_.-]+" => "_")
    return isempty(cleaned) ? "unlabeled" : cleaned
end

function increment_label!(label_counts::Dict{String,Int}, label::String)
    label_counts[label] = get(label_counts, label, 0) + 1
    return label_counts[label]
end

function decrement_label!(label_counts::Dict{String,Int}, label::String)
    next_count = get(label_counts, label, 0) - 1
    if next_count <= 0
        delete!(label_counts, label)
    else
        label_counts[label] = next_count
    end
end

function next_label_index!(label_next_indices::Dict{String,Int}, label::String)
    label_next_indices[label] = get(label_next_indices, label, 0) + 1
    return label_next_indices[label]
end

function labeled_tile_name(label::AbstractString, index::Integer)
    return string(label, "-", lpad(string(index), 3, "0"), ".png")
end

function label_sidecar_path(outdir::AbstractString)
    return joinpath(outdir, "labels.yaml")
end

function record_dict(record::ManualLabelRecord)
    return Dict(
        "order" => record.order_index,
        "row" => record.cell.row_index,
        "column" => record.cell.col_index,
        "label" => record.label,
        "file" => basename(record.tile_path),
    )
end

function write_label_sidecar(
    outdir::AbstractString;
    image_path::AbstractString,
    width::Integer,
    height::Integer,
    nrows::Integer,
    ncols::Integer,
    label_counts::Dict{String,Int},
    records=ManualLabelRecord[],
)
    sidecar_path = label_sidecar_path(outdir)
    labels = Dict(label => label_counts[label] for label in sort(collect(keys(label_counts))))
    data = Dict(
        "image" => String(image_path),
        "width" => Int(width),
        "height" => Int(height),
        "rows" => Int(nrows),
        "columns" => Int(ncols),
        "labels" => labels,
        "records" => [record_dict(record) for record in records],
    )

    YAML.write_file(sidecar_path, data)
    return sidecar_path
end

function ordered_records(records::Vector{Union{Nothing,ManualLabelRecord}})
    return [record for record in records if !isnothing(record)]
end

"""
    split_image_grid(image_path; nrows, ncols, output_dir=nothing, by_hand=true)

Split `image_path` into an `nrows` by `ncols` grid and save the tiles as PNG files.
Returns a `SplitGridResult` with image dimensions and written tile paths.
"""
function split_image_grid(
    image_path::AbstractString;
    nrows::Integer,
    ncols::Integer,
    output_dir::Union{Nothing,AbstractString}=nothing,
    by_hand::Bool=true,
    host::AbstractString="127.0.0.1",
    port::Integer=8080,
)
    if by_hand
        return manual_label_grid(image_path; nrows, ncols, output_dir, host, port)
    end

    return split_image_grid_unlabeled(image_path; nrows, ncols, output_dir)
end

function split_image_grid_unlabeled(
    image_path::AbstractString;
    nrows::Integer,
    ncols::Integer,
    output_dir::Union{Nothing,AbstractString}=nothing,
)
    @assert nrows > 0 "NROWS must be positive"
    @assert ncols > 0 "NCOLS must be positive"

    img = load(image_path)
    height, width = size(img)[1:2]
    cells = grid_cells(height, width, nrows, ncols)

    outdir = isnothing(output_dir) ? output_directory(image_path, nrows, ncols) : String(output_dir)
    assert_missing_or_empty_dir(outdir)
    mkpath(outdir)

    tile_paths = String[]
    for cell in cells
        tile = image_tile(img, cell)
        tile_name = lpad(string(cell.row_index), 3, "0") * "x" * lpad(string(cell.col_index), 3, "0") * ".png"
        tile_path = joinpath(outdir, tile_name)
        save(tile_path, tile)
        push!(tile_paths, tile_path)
    end

    return SplitGridResult(String(image_path), width, height, Int(nrows), Int(ncols), outdir, tile_paths, Dict{String,Int}(), nothing)
end

"""
    split_image_grid(labeler, image_path; nrows, ncols, output_dir=nothing, rng=Random.default_rng())

Split `image_path` in random grid-cell order. `labeler` is called for each cell and
its result is used as the label in file names like `"label-001.png"`. The most
natural callback receives `(row_index, col_index)`.
"""
function split_image_grid(
    labeler::Function,
    image_path::AbstractString;
    nrows::Integer,
    ncols::Integer,
    output_dir::Union{Nothing,AbstractString}=nothing,
    rng::AbstractRNG=Random.default_rng(),
)
    @assert nrows > 0 "NROWS must be positive"
    @assert ncols > 0 "NCOLS must be positive"

    img = load(image_path)
    height, width = size(img)[1:2]
    cells = shuffle(rng, grid_cells(height, width, nrows, ncols))

    outdir = isnothing(output_dir) ? output_directory(image_path, nrows, ncols) : String(output_dir)
    assert_missing_or_empty_dir(outdir)
    mkpath(outdir)

    label_counts = Dict{String,Int}()
    records = ManualLabelRecord[]
    tile_paths = String[]

    for (order_index, cell) in enumerate(cells)
        tile = image_tile(img, cell)
        label = sanitize_label(call_labeler(labeler, tile, cell))
        label_index = increment_label!(label_counts, label)
        tile_path = joinpath(outdir, labeled_tile_name(label, label_index))

        save(tile_path, tile)
        push!(tile_paths, tile_path)
        push!(records, ManualLabelRecord(order_index, cell, label, tile_path))
    end

    sidecar_path = write_label_sidecar(
        outdir;
        image_path,
        width,
        height,
        nrows,
        ncols,
        label_counts,
        records,
    )

    return SplitGridResult(String(image_path), width, height, Int(nrows), Int(ncols), outdir, tile_paths, label_counts, sidecar_path)
end

function call_labeler(labeler::Function, tile, cell::GridCell)
    if applicable(labeler, cell.row_index, cell.col_index)
        return labeler(cell.row_index, cell.col_index)
    elseif applicable(labeler, tile, cell.row_index, cell.col_index)
        return labeler(tile, cell.row_index, cell.col_index)
    elseif applicable(labeler, cell, tile)
        return labeler(cell, tile)
    elseif applicable(labeler, cell)
        return labeler(cell)
    else
        throw(ArgumentError("labeler must accept (row, col), (tile, row, col), (cell, tile), or (cell)"))
    end
end

function manual_label_grid(
    image_path::AbstractString;
    nrows::Integer,
    ncols::Integer,
    output_dir::Union{Nothing,AbstractString}=nothing,
    host::AbstractString="127.0.0.1",
    port::Integer=8080,
    rng::AbstractRNG=Random.default_rng(),
)
    @assert nrows > 0 "NROWS must be positive"
    @assert ncols > 0 "NCOLS must be positive"

    img = load(image_path)
    height, width = size(img)[1:2]
    cells = shuffle(rng, grid_cells(height, width, nrows, ncols))

    outdir = isnothing(output_dir) ? output_directory(image_path, nrows, ncols) : String(output_dir)
    assert_missing_or_empty_dir(outdir)
    mkpath(outdir)

    pending_paths = String[]
    for (order_index, cell) in enumerate(cells)
        tile_path = joinpath(outdir, "_pending-" * lpad(string(order_index), 3, "0") * ".png")
        save(tile_path, image_tile(img, cell))
        push!(pending_paths, tile_path)
    end

    records = Vector{Union{Nothing,ManualLabelRecord}}(undef, length(cells))
    fill!(records, nothing)

    state = ManualLabelState(
        String(image_path),
        Int(width),
        Int(height),
        Int(nrows),
        Int(ncols),
        outdir,
        cells,
        pending_paths,
        records,
        1,
        Dict{String,Int}(),
        Dict{String,Int}(),
        nothing,
        false,
        Channel{Bool}(1),
        ReentrantLock(),
    )

    register_manual_routes!(state)

    url = "http://$(host):$(port)"
    println("Manual labeling UI: ", url)
    println("Press Ctrl+C to stop the server before completion.")

    Oxygen.serve(host=String(host), port=Int(port), async=true, docs=false, show_banner=false)
    take!(state.done_channel)
    Oxygen.terminate()

    return result_from_state(state)
end

function register_manual_routes!(state::ManualLabelState)
    Oxygen.get("/") do req
        return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], manual_label_page())
    end

    Oxygen.get("/state") do _::Oxygen.Request
        return manual_state_snapshot(state)
    end

    Oxygen.get("/tile/{index}") do _::Oxygen.Request, index::Int
        path = tile_path_for_index(state, index)
        return HTTP.Response(200, ["Content-Type" => "image/png"], read(path))
    end

    Oxygen.post("/submit") do req::Oxygen.Request
        data = JSON3.read(String(req.body), Dict{String,Any})
        label = get(data, "label", "")
        return submit_manual_label!(state, label)
    end

    Oxygen.post("/previous") do _::Oxygen.Request
        return previous_manual_label!(state)
    end

    Oxygen.post("/review") do req::Oxygen.Request
        data = JSON3.read(String(req.body), Dict{String,Any})
        index = parse(Int, string(get(data, "index", 1)))
        return review_manual_label!(state, index)
    end

    Oxygen.post("/finish") do _::Oxygen.Request
        return finish_manual_labeling!(state)
    end
end

function tile_path_for_index(state::ManualLabelState, index::Integer)
    lock(state.lock)
    try
        1 <= index <= length(state.cells) || throw(ArgumentError("tile index is out of range"))
        record = state.records[index]
        return isnothing(record) ? state.pending_paths[index] : record.tile_path
    finally
        unlock(state.lock)
    end
end

function labels_snapshot(label_counts::Dict{String,Int})
    return Dict(label => label_counts[label] for label in sort(collect(keys(label_counts))))
end

function next_unlabeled_index(state::ManualLabelState)
    for (index, record) in enumerate(state.records)
        if isnothing(record)
            return index
        end
    end

    return length(state.records) + 1
end

function manual_state_snapshot(state::ManualLabelState)
    lock(state.lock)
    try
        total = length(state.cells)
        index = min(state.current_index, total)
        current_record = total == 0 ? nothing : state.records[index]
        current_label = isnothing(current_record) ? "" : current_record.label

        return Dict(
            "done" => state.done,
            "current_index" => state.current_index,
            "total" => total,
            "tile_url" => state.done ? nothing : "/tile/$(index)?v=$(time())",
            "current_label" => current_label,
            "labels" => labels_snapshot(state.label_counts),
            "records" => [record_dict(record) for record in ordered_records(state.records)],
            "reviewing" => !isnothing(state.review_return_index),
            "output_directory" => state.output_directory,
        )
    finally
        unlock(state.lock)
    end
end

function submit_manual_label!(state::ManualLabelState, raw_label)
    lock(state.lock)
    try
        state.done && return manual_state_snapshot(state)

        index = min(state.current_index, length(state.cells))
        label = resolve_label_prefix!(state, sanitize_label(raw_label))
        record = state.records[index]
        review_return_index = state.review_return_index

        if isnothing(record)
            label_index = next_label_index!(state.label_next_indices, label)
            tile_path = joinpath(state.output_directory, labeled_tile_name(label, label_index))
            mv(state.pending_paths[index], tile_path; force=false)
            state.records[index] = ManualLabelRecord(index, state.cells[index], label, tile_path)
            increment_label!(state.label_counts, label)
        elseif record.label != label
            decrement_label!(state.label_counts, record.label)
            label_index = next_label_index!(state.label_next_indices, label)
            tile_path = joinpath(state.output_directory, labeled_tile_name(label, label_index))
            mv(record.tile_path, tile_path; force=false)
            record.label = label
            record.tile_path = tile_path
            increment_label!(state.label_counts, label)
        end

        write_manual_sidecar(state)

        if isnothing(review_return_index)
            state.current_index = min(index + 1, length(state.cells) + 1)
        else
            state.current_index = min(review_return_index, length(state.cells) + 1)
            state.review_return_index = nothing
        end

        if state.current_index > length(state.cells)
            state.done = true
        else
            state.done = false
        end

        return manual_state_snapshot(state)
    finally
        unlock(state.lock)
    end
end

function previous_manual_label!(state::ManualLabelState)
    lock(state.lock)
    try
        state.done = false
        state.review_return_index = nothing
        state.current_index = max(1, min(state.current_index - 1, length(state.cells)))
        return manual_state_snapshot(state)
    finally
        unlock(state.lock)
    end
end

function review_manual_label!(state::ManualLabelState, index::Integer)
    lock(state.lock)
    try
        1 <= index <= length(state.cells) || throw(ArgumentError("tile index is out of range"))
        isnothing(state.records[index]) && throw(ArgumentError("cannot review an unlabeled tile"))

        state.review_return_index = next_unlabeled_index(state)
        state.current_index = Int(index)
        state.done = false

        return manual_state_snapshot(state)
    finally
        unlock(state.lock)
    end
end

function finish_manual_labeling!(state::ManualLabelState)
    lock(state.lock)
    try
        state.done = true
        isready(state.done_channel) || put!(state.done_channel, true)
        return manual_state_snapshot(state)
    finally
        unlock(state.lock)
    end
end

function resolve_label_prefix!(state::ManualLabelState, raw_label::String)
    lower_label = lowercase(raw_label)
    matches = [label for label in keys(state.label_counts) if startswith(lowercase(label), lower_label)]
    return length(matches) == 1 ? only(matches) : raw_label
end

function write_manual_sidecar(state::ManualLabelState)
    return write_label_sidecar(
        state.output_directory;
        image_path=state.image_path,
        width=state.width,
        height=state.height,
        nrows=state.nrows,
        ncols=state.ncols,
        label_counts=state.label_counts,
        records=ordered_records(state.records),
    )
end

function result_from_state(state::ManualLabelState)
    lock(state.lock)
    try
        records = ordered_records(state.records)
        tile_paths = [record.tile_path for record in records]
        sidecar_path = label_sidecar_path(state.output_directory)
        return SplitGridResult(
            state.image_path,
            state.width,
            state.height,
            state.nrows,
            state.ncols,
            state.output_directory,
            tile_paths,
            copy(state.label_counts),
            sidecar_path,
        )
    finally
        unlock(state.lock)
    end
end

function manual_label_page()
    return raw"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>NameReader Manual Labeling</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem; max-width: 900px; }
    img { max-width: 512px; max-height: 512px; border: 1px solid #ddd; image-rendering: auto; }
    textarea { box-sizing: border-box; display: block; font-size: 1.1rem; margin-top: 1rem; width: 512px; }
    .hint { color: #555; margin: 0.75rem 0; }
    .match { background: #fff3a3; display: inline-block; font-weight: 700; padding: 0.2rem 0.4rem; }
    .labels { margin-top: 1rem; }
    .label-item {
      box-sizing: border-box;
      margin: 0 0.5rem 0.5rem 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      width: 10rem;
    }
    .gallery { display: flex; flex-wrap: wrap; gap: 0.75rem; margin-top: 1rem; }
    .gallery button { background: transparent; border: 1px solid #ddd; cursor: pointer; padding: 0.4rem; }
    .gallery img { border: 0; display: block; max-height: 128px; max-width: 128px; }
    .finish { margin-top: 1rem; }
    .muted { color: #666; }
  </style>
</head>
<body>
  <h1>NameReader Manual Labeling</h1>
  <p id="progress" class="muted"></p>
  <img id="tile" alt="Current grid cell">
  <br/>
  <label for="labelBox" class="hint">
    Type a label. <br/>
    Press <code>enter</code> to submit and proceed to the following image. <br/>
    Press <code>shift+enter</code> to go to a previous image to change it.
  </label>
  <textarea id="labelBox" rows="2" autofocus></textarea>
  <p id="suggestion"></p>
  <div class="labels">
    <strong>Labels</strong>
    <div id="labels"></div>
  </div>
  <div id="gallery" class="gallery"></div>
  <button id="finishButton" class="finish" hidden>Finish and stop server</button>

  <script>
    const tile = document.getElementById("tile");
    const progress = document.getElementById("progress");
    const box = document.getElementById("labelBox");
    const suggestion = document.getElementById("suggestion");
    const labels = document.getElementById("labels");
    const gallery = document.getElementById("gallery");
    const finishButton = document.getElementById("finishButton");
    let state = { labels: {} };

    function uniqueMatch(value) {
      const query = value.trim().toLowerCase();
      if (!query) return null;
      const matches = Object.keys(state.labels || {}).filter(label => label.toLowerCase().startsWith(query));
      return matches.length === 1 ? matches[0] : null;
    }

    function render(nextState) {
      state = nextState;
      labels.innerHTML = "";
      Object.entries(state.labels || {}).forEach(([label, count]) => {
        const button = document.createElement("button");
        button.className = "label-item";
        button.type = "button";
        button.textContent = `${label} (${count})`;
        button.addEventListener("click", () => showLabelImages(label));
        labels.appendChild(button);
      });
      finishButton.hidden = !state.done;

      if (state.done) {
        progress.textContent = `Complete. Saved ${state.records.length} images to ${state.output_directory}.`;
        tile.removeAttribute("src");
        tile.hidden = true;
        box.disabled = true;
        suggestion.textContent = "";
        return;
      }

      progress.textContent = state.reviewing ?
        `Reviewing image ${state.current_index} of ${state.total}` :
        `Image ${state.current_index} of ${state.total}`;
      tile.hidden = false;
      tile.src = state.tile_url;
      box.disabled = false;
      box.value = state.current_label || "";
      box.focus();
      updateSuggestion();
    }

    function updateSuggestion() {
      const match = uniqueMatch(box.value);
      suggestion.innerHTML = match ? `Unique match: <span class="match">${match}</span>` : "";
    }

    function showLabelImages(label) {
      gallery.innerHTML = "";
      (state.records || [])
        .filter(record => record.label === label)
        .forEach(record => {
          const button = document.createElement("button");
          button.type = "button";
          button.title = `Row ${record.row}, column ${record.column}`;

          const image = document.createElement("img");
          image.src = `/tile/${record.order}?v=${Date.now()}`;
          image.alt = `${label}: row ${record.row}, column ${record.column}`;

          button.appendChild(image);
          button.addEventListener("click", () => reviewImage(record.order));
          gallery.appendChild(button);
        });
    }

    async function refresh() {
      const response = await fetch("/state");
      render(await response.json());
    }

    async function submit() {
      const match = uniqueMatch(box.value);
      const label = match || box.value;
      const response = await fetch("/submit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ label })
      });
      render(await response.json());
    }

    async function reviewImage(index) {
      gallery.innerHTML = "";
      const response = await fetch("/review", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ index })
      });
      render(await response.json());
    }

    async function previous() {
      const response = await fetch("/previous", { method: "POST" });
      render(await response.json());
    }

    async function finish() {
      const response = await fetch("/finish", { method: "POST" });
      render(await response.json());
    }

    box.addEventListener("input", updateSuggestion);
    finishButton.addEventListener("click", finish);
    box.addEventListener("keydown", event => {
      if (event.key !== "Enter") return;
      event.preventDefault();
      gallery.innerHTML = "";
      if (event.shiftKey) {
        previous();
      } else {
        submit();
      }
    });

    refresh();
  </script>
</body>
</html>
"""
end

function print_summary(result::SplitGridResult)
    println("Image: ", result.image_path)
    println("Width: ", result.width)
    println("Height: ", result.height)
    println("Rows: ", result.nrows)
    println("Columns: ", result.ncols)
    println("Saved ", length(result.tile_paths), " tiles to ", result.output_directory)
    if !isnothing(result.sidecar_path)
        println("Sidecar: ", result.sidecar_path)
    end
end

