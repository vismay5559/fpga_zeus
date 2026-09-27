`default_nettype none
// Emits a 1-clock-cycle pulse on `tick` every DIV clock cycles.
// First building block of the UART (baud tick) and of every timed process.
module tick_gen #(
    parameter integer DIV = 100_000_000   // must be >= 2
)(
    input  wire clk,
    input  wire rst,     // synchronous, active high
    output reg  tick
);
    localparam integer W = $clog2(DIV);
    reg [W-1:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            cnt  <= {W{1'b0}};
            tick <= 1'b0;
        end else if (cnt == DIV - 1) begin
            cnt  <= {W{1'b0}};
            tick <= 1'b1;
        end else begin
            cnt  <= cnt + 1'b1;
            tick <= 1'b0;
        end
    end
endmodule
`default_nettype wire
