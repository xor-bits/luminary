use eyre::Result;

use crate::graphics::Graphics;

//

pub struct Renderer<'a> {
    ctx: &'a Graphics,
}

impl<'a> Renderer<'a> {
    pub fn new(ctx: &'a Graphics) -> Result<Self> {
        Ok(Self { ctx })
    }
}
