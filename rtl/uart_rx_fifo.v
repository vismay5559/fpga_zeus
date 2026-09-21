`default_nettype none
// Complete receive path for raw UART bytes:
//
//     asynchronous rx pin -> uart_rx -> fifo_sync -> byte consumer
//
// uart_rx converts one 8N1 serial frame into an 8-bit byte and pulses
// rx_byte_valid for one clock. That pulse is wired directly to the FIFO write
// request, so every good UART byte is queued automatically. The future SHTP
// decoder will become the consumer and will pulse rd_en whenever it wants the
// oldest queued byte.
module uart_rx_fifo #(
    parameter integer CLKS_PER_BIT = 33,
    parameter integer FIFO_DEPTH  = 16
)(
    input  wire clk,
    input  wire rst,
    input  wire rx,

    // Consumer side. A read is accepted on a rising edge when !empty.
    input  wire rd_en,
    output wire [7:0] rd_data,
    output wire rd_valid,

    // Queue status and diagnostics.
    output wire empty,
    output wire full,
    output wire [$clog2(FIFO_DEPTH+1)-1:0] level,
    output wire overflow,
    output wire underflow,
    output wire frame_error
);
    // STEP 1: The UART receiver creates parallel bytes from serial bits.
    wire [7:0] rx_byte;
    wire       rx_byte_valid;

    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_receiver (
        .clk        (clk),
        .rst        (rst),
        .rx         (rx),
        .data       (rx_byte),
        .valid      (rx_byte_valid),
        .frame_error(frame_error)
    );

    // STEP 2: A valid UART byte becomes a FIFO write automatically.
    // The FIFO is 8 bits wide because a UART frame delivers one 8-bit byte.
    fifo_sync #(
        .WIDTH(8),
        .DEPTH(FIFO_DEPTH)
    ) receive_queue (
        .clk      (clk),
        .rst      (rst),
        .wr_en    (rx_byte_valid),
        .wr_data  (rx_byte),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_valid (rd_valid),
        .full     (full),
        .empty    (empty),
        .level    (level),
        .overflow (overflow),
        .underflow(underflow)
    );
endmodule
`default_nettype wire
