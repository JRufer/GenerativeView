//! GenerativeView core: reads generation metadata out of AI images, keeps a
//! searchable index of a folder in step with the disk, and serves thumbnails.

pub mod clip;
pub mod dates;
pub mod db;
pub mod dupes;
pub mod engine;
pub mod ffi;
pub mod fsnav;
pub mod index;
pub mod meta;
pub mod notes;
pub mod sr;
pub mod thumbs;
pub mod upscale;
