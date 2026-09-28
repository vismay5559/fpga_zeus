`default_nettype none
// Bench top: real foot contacts, invalid/zero IMU, encoder and CAN records.
// TEST_MODE marks this as a demo. It drives the Pi-compatible SPI frame.
module pi_link_demo_top #(
    parameter integer CLKS_PER_US = 100,
    parameter integer POR_BITS = 16
)(
    input wire CLK100MHZ,
    input wire [0:0] btn,
    input wire [1:0] foot_sw_n,
    output wire [2:0] led,
    input wire pi_sck, pi_cs_n,
    output wire pi_miso, pi_data_ready
);
    reg [POR_BITS-1:0] por_count = 0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn_sync = 0;
    always @(posedge CLK100MHZ) begin
        btn_sync <= {btn_sync[0], btn[0]};
        if (!(&por_count)) por_count <= por_count + 1'b1;
    end
    wire rst = !(&por_count) || btn_sync[1];
    wire sample;
    reg sample_for_link;
    wire [63:0] timestamp_us;
    wire [1:0] switches, unused_switch_changed;
    wire [1:0] feet, unused_foot_changed;
    wire [15:0] left_ticks, right_ticks;
    wire [63:0] latest_change_us;
    wire [127:0] unused_switch_change_us;
    wire [127:0] contact_record;
    reg [4847:0] payload;
    wire miso;
    wire unused_ready, unused_accepted;
    wire [31:0] unused_dropped, unused_sequence;

    cycle_timer #(.CLKS_PER_US(CLKS_PER_US)) timer (
        .clk(CLK100MHZ), .rst(rst), .sample(sample),
        .timestamp_us(timestamp_us)
    );
    foot_switches contacts (
        .clk(CLK100MHZ), .rst(rst), .sample(sample),
        .raw_n(foot_sw_n), .now_us(timestamp_us),
        .switches(switches), .feet(feet),
        .left_ticks(left_ticks), .right_ticks(right_ticks),
        .switch_changed(unused_switch_changed),
        .foot_changed(unused_foot_changed),
        .switch_change_us(unused_switch_change_us),
        .latest_change_us(latest_change_us)
    );
    // The switch bank updates on `sample`; capture it one clock afterward.
    always @(posedge CLK100MHZ) begin
        if (rst) sample_for_link <= 1'b0;
        else sample_for_link <= sample;
    end
    // Relative packet byte 432 = absolute frame byte 464.
    // Byte0 left/right switches; byte1 identical feet; 2..3 zero; 4..7 ages; 8..15 time.
    assign contact_record = {
        latest_change_us, right_ticks, left_ticks, 16'b0,
        6'b0, feet, 6'b0, switches
    };
    always @* begin
        payload = 4848'b0;
        payload[3456 +: 128] = contact_record;
    end
    pi_link link (
        .clk(CLK100MHZ), .rst(rst), .sample(sample_for_link),
        .timestamp_us(timestamp_us),
        .flags(32'h80000004), // TEST_MODE + contacts present
        .payload(payload), .spi_sck(pi_sck), .spi_cs_n(pi_cs_n),
        .spi_miso(miso), .data_ready(pi_data_ready),
        .sample_ready(unused_ready), .sample_accepted(unused_accepted),
        .dropped(unused_dropped), .sequence_next(unused_sequence)
    );
    assign pi_miso = pi_cs_n ? 1'bz : miso;
    assign led[0] = pi_data_ready;
    assign led[1] = feet[0];
    assign led[2] = feet[1];
endmodule
`default_nettype wire
