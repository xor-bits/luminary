use glam::{Mat3, Mat4, Vec2, Vec3};

//

pub struct Flycam {
    position: Vec3,
    yaw: f32,
    pitch: f32,
}

impl Flycam {
    pub const fn new() -> Self {
        Self {
            position: Vec3::splat(-5.0),
            yaw: 0.0,
            pitch: 0.0,
        }
    }

    pub fn movement(&mut self, delta: Vec3) {
        self.position += Mat3::from_rotation_y(self.yaw) * delta;

        tracing::info!("pos={}", self.position);
    }

    pub fn mouse_delta(&mut self, delta: Vec2) {
        self.yaw -= delta.x * 0.001;
        self.pitch += delta.y * 0.001;

        self.pitch = self.pitch.clamp(
            -std::f32::consts::FRAC_PI_2 + f32::EPSILON,
            std::f32::consts::FRAC_PI_2 - f32::EPSILON,
        );

        // tracing::info!("yaw={} pitch={}", self.yaw, self.pitch);
        tracing::info!("looking_to={}", self.looking_to());
    }

    /// view matrix
    pub fn view_matrix(&self) -> Mat4 {
        let eye = self.position;
        let dir = self.looking_to();
        Mat4::look_to_rh(eye, dir, Vec3::NEG_Y)
    }

    pub fn looking_to(&self) -> Vec3 {
        let yaw_sin = self.yaw.sin();
        let yaw_cos = self.yaw.cos();
        let pitch_sin = self.pitch.sin();
        let pitch_cos = self.pitch.cos();
        Vec3::new(yaw_sin * pitch_cos, pitch_sin, yaw_cos * pitch_cos)
    }
}
