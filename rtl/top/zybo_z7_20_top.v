`default_nettype none
// First power-up image: LED0 blinks at 1 Hz; BTN0 holds it off.
module zybo_z7_20_top (
    input wire clk125,
    input wire btn0,
    output reg led0
);
    wire clk100, locked;
    zybo_z7_20_clock u_clock (.clk125(clk125), .clk100(clk100), .locked(locked));
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn_sync = 0;
    reg [26:0] count = 0;
    always @(posedge clk100) begin
        btn_sync <= {btn_sync[0], btn0};
        if (!locked || btn_sync[1]) begin
            count <= 0;
            led0 <= 0;
        end else if (count == 99_999_999) begin
            count <= 0;
            led0 <= ~led0;
        end else count <= count + 1'b1;
    end
endmodule
`default_nettype wire
