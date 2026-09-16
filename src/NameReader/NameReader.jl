module NameReader

using ..Paths: package_root
using ..JsonIO

"""
    NameReader

Detect student names on scanned assignment pages.

Source handwriting samples can be a flat labeled-tile folder (`label-001.png`)
or a folder of per-student directories, which is what `NameStore` maintains:

```text
<lastname,firstname>/
  table_<id>.png    crop from a handwritten name table; composited onto a blank name line
  assn_<id>.png     crop from a scanned assignment's name line; used as scanned
```

The two origins are augmented differently and split into training and testing
sets independently. See `name_image_kind` and `split_name_handwriting`.
"""

include("split_image_grid.jl")
include("image_augmentation.jl")
include("image_utils.jl")
include("ml_classifier.jl")
include("compose.jl")
include("embedding_model.jl")
include("train_names.jl")

export GridCell
export SplitGridResult
export image_dimensions
export output_directory
export split_image_grid
export print_summary
export AugmentedDatasetResult
export augment_image
export augment_image_file
export preview_augmentations
export save_preview_batch
export save_augmented_dataset
export max_image_dimensions
export resize_images_with_padding
export thin_images_in_folder
export label_from_tile_path
export SymbolImageDataset
export SymbolClassifier
export SymbolTrainingResult
export load_symbol_dataset
export create_symbol_classifier
export train_symbol_classifier
export train_symbol_classifier_on_demand
export evaluate_symbol_classifier
export print_confusion_matrix
export save_symbol_classifier
export load_symbol_classifier
export predict_symbol
export symbol_embeddings
export SymbolSourceDataset
export load_symbol_source_datasets

export SymbolEmbeddingModel
export SymbolGallery
export SymbolSourceSplit
export SymbolEmbeddingResult
export create_symbol_embedder
export split_symbol_sources
export train_symbol_embedder
export build_symbol_gallery
export enroll_symbol!
export remove_symbol!
export embed_symbol
export match_symbol
export symbol_score_matrix
export evaluate_symbol_gallery
export assign_symbols_to_roster
export print_assignment_report
export print_symbol_metrics
export save_symbol_embedder
export load_symbol_embedder
export save_symbol_gallery
export load_symbol_gallery

export NAME_FIELD_SIZE
export background_training_dir
export prepare_name_image
export compose_name_training_image
export compose_assignment_training_image
export load_background_images
export preview_name_training_samples
export NameReaderBundle
export train_name_reader
export save_name_reader
export load_name_reader
export class_stem_from_training_dir
export guess_assignment_names

export NAME_TABLE_IMAGE_PREFIX
export ASSIGNMENT_IMAGE_PREFIX
export NAME_IMAGE_KINDS
export name_image_kind
export name_image_id
export name_image_prefix
export group_name_paths_by_student
export read_training_sidecar
export write_training_sidecar

end # module
