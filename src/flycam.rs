use glam::{Mat4, Vec2, Vec3};

//

pub struct Flycam {
    position: Vec3,
    yaw: f32,
    pitch: f32,
}

impl Flycam {
    pub const fn new() -> Self {
        Self {
            position: Vec3::ZERO,
            yaw: 0.0,
            pitch: 0.0,
        }
    }

    pub fn movement(&mut self, delta: Vec3) {
        self.position += delta;
    }

    pub fn mouse_delta(&mut self, delta: Vec2) {
        self.yaw -= delta.x * 0.001;
        self.pitch -= delta.y * 0.001;

        self.pitch = self
            .pitch
            .clamp(-std::f32::consts::FRAC_PI_2, std::f32::consts::FRAC_PI_2);

        tracing::info!("yaw={} pitch={}", self.yaw, self.pitch);
    }

    /// view matrix
    pub fn view_matrix(&self) -> Mat4 {
        let yaw_sin = self.yaw.sin();
        let yaw_cos = self.yaw.cos();
        let pitch_sin = self.pitch.sin();
        let pitch_cos = self.pitch.cos();

        let eye = self.position;
        let dir =
            Vec3::new(yaw_sin * pitch_cos, pitch_sin, yaw_cos * pitch_cos);

        Mat4::look_to_lh(eye, dir, Vec3::NEG_Y)
    }
}
