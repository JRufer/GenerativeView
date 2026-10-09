//! GenerativeView core: reads generation metadata out of AI images, keeps a
//! searchable index of a folder in step with the disk, and serves thumbnails.

pub mod db;
pub mod engine;
pub mod ffi;
pub mod fsnav;
pub mod index;
pub mod meta;
pub mod thumbs;
