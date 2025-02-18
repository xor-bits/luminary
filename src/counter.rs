use std::time::{Duration, Instant};

use crate::cold;

//

pub struct Counter {
    count: usize,
    last_time: Instant,
    interval: Duration,
}

impl Counter {
    pub fn new(interval: Duration) -> Self {
        Self {
            count: 0,
            last_time: Instant::now(),
            interval,
        }
    }

    /// returns the number of times this function has
    /// been called per second on average
    pub fn next(&mut self) -> Option<f32> {
        self.count += 1;

        let elapsed = self.last_time.elapsed();
        if elapsed >= self.interval {
            cold();

            let count = self.count;
            self.count = 0;
            self.last_time = Instant::now();

            return Some((count as f64 / elapsed.as_secs_f64()) as f32);
        }

        None
    }
}
