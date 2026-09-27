`default_nettype none
// Packet layer and physical SPI read transport; upstream payload is in clk domain.
module pi_link (
    input wire clk, rst, sample,
    input wire [63:0] timestamp_us,
    input wire [31:0] flags,
    input wire [4847:0] payload,
    input wire spi_sck, spi_cs_n,
    output wire spi_miso, data_ready,
    output wire sample_ready, sample_accepted,
    output wire [31:0] dropped, sequence_next
);
    wire [7:0] data;
    wire valid, ready, last, rewind;
    wire unused_busy;
    pi_snapshot packet (
        .clk(clk), .rst(rst), .sample(sample), .timestamp_us(timestamp_us),
        .flags(flags), .payload(payload), .rewind(rewind),
        .sample_ready(sample_ready), .sample_accepted(sample_accepted),
        .busy(unused_busy), .dropped(dropped), .sequence_next(sequence_next),
        .out_data(data), .out_valid(valid), .out_last(last), .out_ready(ready)
    );
    pi_spi_slave transport (
        .clk(clk), .rst(rst), .spi_sck(spi_sck), .spi_cs_n(spi_cs_n),
        .spi_miso(spi_miso), .in_data(data), .in_valid(valid), .in_last(last),
        .in_ready(ready), .rewind(rewind), .data_ready(data_ready)
    );
endmodule
`default_nettype wire
