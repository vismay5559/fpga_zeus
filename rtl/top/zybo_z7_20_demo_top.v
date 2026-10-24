`default_nettype none
// Z7-20 wrapper around the existing 100 MHz IMU/contact/Pi bench demo.
// The MMCM lock holds the demo in reset until its 100 MHz clock is stable.
module zybo_z7_20_demo_top (
    input wire clk125,
    input wire btn0,
    input wire [1:0] foot_sw_n,
    input wire imu_rx,
    output wire imu_tx,
    output wire [2:0] led,
    input wire pi_sck, pi_cs_n,
    output wire pi_miso, pi_data_ready
);
    wire clk100, locked;
    zybo_z7_20_clock u_clock (.clk125(clk125), .clk100(clk100), .locked(locked));
    pi_link_demo_top demo (
        .CLK100MHZ(clk100), .btn(~locked | btn0),
        .foot_sw_n(foot_sw_n), .imu_rx(imu_rx), .imu_tx(imu_tx),
        .led(led), .pi_sck(pi_sck), .pi_cs_n(pi_cs_n),
        .pi_miso(pi_miso), .pi_data_ready(pi_data_ready)
    );
endmodule
`default_nettype wire
