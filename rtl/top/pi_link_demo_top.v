`default_nettype none
// Board test only: invalid/zero sensor payload, TEST_MODE flag, 1 kHz snapshots.
module pi_link_demo_top (
    input wire CLK100MHZ,
    input wire [0:0] btn,
    output wire [0:0] led,
    input wire pi_sck, pi_cs_n,
    output wire pi_miso, pi_data_ready
);
    reg [15:0] por_count = 0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn_sync = 0;
    always @(posedge CLK100MHZ) begin
        btn_sync <= {btn_sync[0], btn[0]};
        if (!(&por_count)) por_count <= por_count + 1'b1;
    end
    wire rst = !(&por_count) || btn_sync[1];
    wire sample;
    wire [63:0] timestamp_us;
    wire miso;
    wire unused_ready, unused_accepted;
    wire [31:0] unused_dropped, unused_sequence;
    cycle_timer timer (.clk(CLK100MHZ), .rst(rst), .sample(sample),
                       .timestamp_us(timestamp_us));
    pi_link link (
        .clk(CLK100MHZ), .rst(rst), .sample(sample), .timestamp_us(timestamp_us),
        .flags(32'h80000000), .payload(4848'b0),
        .spi_sck(pi_sck), .spi_cs_n(pi_cs_n), .spi_miso(miso),
        .data_ready(pi_data_ready), .sample_ready(unused_ready),
        .sample_accepted(unused_accepted), .dropped(unused_dropped),
        .sequence_next(unused_sequence)
    );
    assign pi_miso = pi_cs_n ? 1'bz : miso;
    assign led[0] = pi_data_ready;
endmodule
`default_nettype wire
