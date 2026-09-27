`default_nettype none
// Free-running microsecond time and 1 kHz strobe in one clock domain.
module cycle_timer #(
    parameter integer CLKS_PER_US=100,
    parameter integer SAMPLE_US=1000
)(input wire clk, rst, output reg sample, output reg [63:0] timestamp_us);
    localparam integer CW = (CLKS_PER_US < 2) ? 1 : $clog2(CLKS_PER_US);
    localparam integer SW = (SAMPLE_US < 2) ? 1 : $clog2(SAMPLE_US);
    localparam integer CLOCK_LAST_I = CLKS_PER_US-1;
    localparam [CW-1:0] CLOCK_LAST = CLOCK_LAST_I[CW-1:0];
    localparam integer SAMPLE_LAST_I = SAMPLE_US-1;
    localparam [SW-1:0] SAMPLE_LAST = SAMPLE_LAST_I[SW-1:0];
    reg [CW-1:0] cycles;
    reg [SW-1:0] micros;
    always @(posedge clk) begin
        if (rst) begin cycles<=0; micros<=0; sample<=0; timestamp_us<=0; end
        else begin
            // TODO 1 (implemented): divide cycles into microseconds.
            sample <= 0;
            if (cycles == CLOCK_LAST) begin
                cycles <= 0; timestamp_us <= timestamp_us + 1'b1;
                // TODO 2 (implemented): sample and timestamp become visible
                // together; downstream captures them on the following edge.
                if (micros == SAMPLE_LAST) begin micros<=0; sample<=1; end
                else micros<=micros+1'b1;
            end else cycles<=cycles+1'b1;
        end
    end
endmodule
`default_nettype wire
