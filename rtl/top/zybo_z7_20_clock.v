`default_nettype none
// Zybo Z7 PL clock: 125 MHz on K17 -> 100 MHz for the existing UART/timer RTL.
// 125 MHz / DIVCLK(1) * MULT(8) = 1000 MHz VCO; / OUTDIV(10) = 100 MHz.
module zybo_z7_20_clock (
    input wire clk125,
    output wire clk100,
    output wire locked
);
    wire clk_fb, clk_fb_buf, clk100_raw;
    BUFG feedback (.I(clk_fb), .O(clk_fb_buf));
    BUFG output_buf (.I(clk100_raw), .O(clk100));
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(8.000),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(8.000),
        .CLKOUT0_DIVIDE_F(10.000),
        .CLKOUT0_DUTY_CYCLE(0.500)
    ) mmcm (
        .CLKIN1(clk125), .CLKFBIN(clk_fb_buf),
        .CLKFBOUT(clk_fb), .CLKOUT0(clk100_raw), .LOCKED(locked),
        .PWRDWN(1'b0), .RST(1'b0)
    );
endmodule
`default_nettype wire
