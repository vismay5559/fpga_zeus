`default_nettype none
// Sensor-only first hardware test. LEDs show startup/report milestones, not rate.
module zybo_z7_20_imu_top (
    input wire clk125,
    input wire btn0,
    input wire imu_rx,
    output wire imu_tx,
    output wire [3:0] led
);
    wire clk100, locked;
    zybo_z7_20_clock u_clock (.clk125(clk125), .clk100(clk100), .locked(locked));
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn_sync = 0;
    reg [15:0] por_count = 0;
    always @(posedge clk100) begin
        btn_sync <= {btn_sync[0], btn0};
        if (!(&por_count)) por_count <= por_count + 1'b1;
    end
    wire rst = !locked || !(&por_count) || btn_sync[1];
    wire snapshot;
    wire [63:0] unused_timestamp_us;
    cycle_timer timer (
        .clk(clk100), .rst(rst), .sample(snapshot),
        .timestamp_us(unused_timestamp_us)
    );
    wire configured, accel_has_sample, gyro_has_sample, rotation_has_sample;
    // This first-test image intentionally leaves the detailed data outputs unused.
    /* verilator lint_off PINMISSING */
    bno085_imu #(.MAX_PACKET_BYTES(128)) imu (
        .clk(clk100), .rst(rst), .rx(imu_rx), .tx(imu_tx),
        .snapshot(snapshot), .configured(configured),
        .accel_has_sample(accel_has_sample),
        .gyro_has_sample(gyro_has_sample),
        .rotation_has_sample(rotation_has_sample)
    );
    /* verilator lint_on PINMISSING */
    reg [26:0] blink_count = 0;
    reg heartbeat = 0;
    always @(posedge clk100) begin
        if (rst) begin blink_count <= 0; heartbeat <= 0; end
        else if (blink_count == 99_999_999) begin
            blink_count <= 0;
            heartbeat <= ~heartbeat;
        end else blink_count <= blink_count + 1'b1;
    end
    assign led = {rotation_has_sample, accel_has_sample & gyro_has_sample,
                  configured, heartbeat};
endmodule
`default_nettype wire
