`default_nettype none
// Read-only SPI mode 0, MSB first, synchronized into clk (100 MHz).
// SCK <= 10 MHz; CS setup/hold >=100 ns; CS high between transactions >=200 ns.
// Read exactly 640 bytes after data_ready. Aborted reads rewind the same frame.
module pi_spi_slave (
    input wire clk, rst,
    input wire spi_sck, spi_cs_n,
    output wire spi_miso,
    input wire [7:0] in_data,
    input wire in_valid, in_last,
    output reg in_ready, rewind,
    output wire data_ready
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sck_sync, cs_sync;
    reg sck_prev, cs_prev;
    reg active, complete;
    reg [2:0] bit_index;
    reg [7:0] shift;
    wire sck_rise = sck_sync[1] && !sck_prev;
    wire sck_fall = !sck_sync[1] && sck_prev;
    wire cs_fall = !cs_sync[1] && cs_prev;
    wire cs_rise = cs_sync[1] && !cs_prev;
    assign data_ready = in_valid;
    assign spi_miso = shift[7]; // board top supplies CS-controlled tristate
    always @(posedge clk) begin
        if (rst) begin
            sck_sync <= 0; cs_sync <= 2'b11;
            sck_prev <= 0; cs_prev <= 1;
            active <= 0; complete <= 0; bit_index <= 0; shift <= 0;
            in_ready <= 0; rewind <= 0;
        end else begin
            // TODO 1 (implemented): synchronize external control signals.
            sck_sync <= {sck_sync[0], spi_sck};
            cs_sync <= {cs_sync[0], spi_cs_n};
            sck_prev <= sck_sync[1]; cs_prev <= cs_sync[1];
            in_ready <= 0; rewind <= 0;
            // TODO 2 (implemented): preload the first bit BEFORE the first SCK.
            if (cs_sync[1]) shift <= in_valid ? in_data : 8'b0;
            if (cs_fall) begin
                active <= in_valid; complete <= 0; bit_index <= 0;
                shift <= in_valid ? in_data : 8'b0;
            end else if (cs_rise) begin
                // An early CS release retries the immutable snapshot, including
                // when a transaction ended halfway through a byte.
                rewind <= active && !complete;
                active <= 0; bit_index <= 0;
            end else if (!cs_sync[1] && active && !complete) begin
                // TODO 3 (implemented): master samples rising edges; advance the
                // byte stream only after eight sampled bits, never on prefetch.
                if (sck_rise) begin
                    if (bit_index == 3'd7) begin
                        bit_index <= 0; in_ready <= 1;
                        if (in_last) complete <= 1;
                    end else bit_index <= bit_index + 1'b1;
                end
                // TODO 4 (implemented): next bit becomes visible on falling edge.
                if (sck_fall) begin
                    if (bit_index == 0) shift <= in_data;
                    else shift <= {shift[6:0], 1'b0};
                end
            end else if (complete) shift <= 0;
        end
    end
endmodule
`default_nettype wire
