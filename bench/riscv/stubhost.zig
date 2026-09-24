const harness = @import("harness");

pub const main = harness.consumer.Consumer(harness.stubhost.Riscv).main;
