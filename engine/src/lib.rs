//! photo-grade engine: non-destructive, high-precision color grading core.
//!
//! All processing happens in 32-bit float. Edits are described by a [`Recipe`]
//! (pure parameters), so presets, auto-grading, reference matching and AI
//! requests all produce recipes that apply losslessly at full resolution.

pub mod adapt;
pub mod analysis;
pub mod color;
pub mod ffi;
pub mod io;
pub mod lut;
pub mod matching;
pub mod pipeline;
pub mod presets;
pub mod recipe;

pub use pipeline::{apply, Image};
pub use recipe::Recipe;
