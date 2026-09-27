`default_nettype none
// Arty A7-100T blinky: LED0 toggles once per second, BTN0 resets.
module top (
    input  wire       CLK100MHZ,
    input  wire [0:0] btn,
    output reg  [0:0] led
);
    // Buttons are asynchronous: pass through a 2-flop synchronizer first.
    reg [1:0] rst_sync;
    always @(posedge CLK100MHZ) rst_sync <= {rst_sync[0], btn[0]};
    wire rst = rst_sync[1];

    wire tick_1hz;
    tick_gen #(.DIV(100_000_000)) u_tick (
        .clk (CLK100MHZ),
        .rst (rst),
        .tick(tick_1hz)
    );

    always @(posedge CLK100MHZ) begin
        if (rst)           led[0] <= 1'b0;
        else if (tick_1hz) led[0] <= ~led[0];
    end
endmodule
`default_nettype wire
