`default_nettype none
// Complete BNO085 receive transport:
//
//   asynchronous 3 Mbaud RX pin
//        -> uart_rx -> fifo_sync -> registered-read bridge
//        -> SHTP UART deframer -> validated packet byte stream
//
// This block stops at validated SHTP packets. A later SH-2 parser will interpret
// channels and turn report payloads into acceleration, gyro and quaternion
// registers.
module bno085_uart_rx #(
    parameter integer CLKS_PER_BIT    = 33,
    parameter integer FIFO_DEPTH     = 16,
    parameter integer MAX_PACKET_BYTES = 512,
    parameter integer TIMEOUT_CYCLES = 1000000
)(
    input  wire clk,
    input  wire rst,
    input  wire rx,

    output wire       packet_start,
    output wire [7:0] packet_protocol,
    output wire [$clog2(MAX_PACKET_BYTES+1)-1:0] packet_len,
    output wire [7:0] out_data,
    output wire       out_valid,
    input  wire       out_ready,
    output wire       out_first,
    output wire       out_last,

    output wire [$clog2(FIFO_DEPTH+1)-1:0] fifo_level,
    output wire       fifo_full,
    output wire       recovery_active,
    output reg [31:0] uart_frame_error_count,
    output reg [31:0] fifo_overflow_count,
    output wire [31:0] invalid_protocol_count,
    output wire [31:0] escape_error_count,
    output wire [31:0] length_error_count,
    output wire [31:0] oversize_error_count,
    output wire [31:0] timeout_error_count,
    output wire [31:0] continuation_error_count
);
    wire [7:0] fifo_data;
    wire       fifo_valid;
    wire       fifo_empty;
    wire       fifo_overflow;
    wire       fifo_underflow;
    wire       uart_frame_error;
    wire       fifo_rd_en;

    reg  [7:0] bridge_data;
    reg        bridge_valid;
    reg        fifo_read_pending;
    reg        flushing;

    wire deframer_ready;
    wire bridge_take = bridge_valid && deframer_ready;
    wire recovery_event = uart_frame_error || fifo_overflow || fifo_underflow;

    // TODO 1 (implemented): Convert serial frames to bytes and queue every good
    // byte. uart_rx_fifo already rejects bad-stop-bit frames.
    uart_rx_fifo #(
        .CLKS_PER_BIT(CLKS_PER_BIT),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) serial_byte_queue (
        .clk       (clk),
        .rst       (rst),
        .rx        (rx),
        .rd_en     (fifo_rd_en),
        .rd_data   (fifo_data),
        .rd_valid  (fifo_valid),
        .empty     (fifo_empty),
        .full      (fifo_full),
        .level     (fifo_level),
        .overflow  (fifo_overflow),
        .underflow (fifo_underflow),
        .frame_error(uart_frame_error)
    );

    // TODO 2 (implemented): Drain the FIFO during recovery. Otherwise request
    // one registered FIFO read only when the bridge has space. One outstanding
    // read is tracked because rd_data/rd_valid arrive after the request edge.
    assign fifo_rd_en = flushing
                      ? !fifo_empty
                      : (!fifo_empty && !fifo_read_pending
                         && (!bridge_valid || bridge_take));

    assign recovery_active = flushing;

    // TODO 3 (implemented): Hold each registered FIFO result until the
    // deframer accepts it. This adapts the FIFO's one-cycle rd_valid pulse to a
    // valid/ready stream where valid and data may need to wait many clocks.
    always @(posedge clk) begin
        if (rst) begin
            bridge_data      <= 8'h00;
            bridge_valid     <= 1'b0;
            fifo_read_pending <= 1'b0;
            flushing         <= 1'b0;
        end else if (recovery_event) begin
            bridge_valid      <= 1'b0;
            fifo_read_pending <= 1'b0;
            flushing          <= 1'b1;
        end else if (flushing) begin
            bridge_valid      <= 1'b0;
            fifo_read_pending <= 1'b0;
            if (fifo_empty)
                flushing <= 1'b0;
        end else begin
            fifo_read_pending <= fifo_rd_en;

            if (bridge_take)
                bridge_valid <= 1'b0;

            if (fifo_valid) begin
                bridge_data  <= fifo_data;
                bridge_valid <= 1'b1;
            end
        end
    end

    // TODO 4 (implemented): Count every bad UART frame and every rejected FIFO
    // write. Saturation prevents a long-running fault from wrapping to zero.
    function automatic [31:0] sat_inc;
        input [31:0] value;
        begin
            sat_inc = (&value) ? value : value + 1'b1;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            uart_frame_error_count <= 32'd0;
            fifo_overflow_count    <= 32'd0;
        end else begin
            if (uart_frame_error)
                uart_frame_error_count <= sat_inc(uart_frame_error_count);
            if (fifo_overflow)
                fifo_overflow_count <= sat_inc(fifo_overflow_count);
        end
    end

    // TODO 5 (implemented): Deframe only held, loss-free bytes. Any upstream
    // loss aborts a partial frame; stale queued bytes are drained before input
    // resumes. A packet already validated by the deframer finishes emitting.
    shtp_uart_deframer #(
        .MAX_PACKET_BYTES(MAX_PACKET_BYTES),
        .TIMEOUT_CYCLES  (TIMEOUT_CYCLES)
    ) packet_deframer (
        .clk                     (clk),
        .rst                     (rst),
        .in_data                 (bridge_data),
        .in_valid                (bridge_valid),
        .in_ready                (deframer_ready),
        .stream_abort            (recovery_event),
        .packet_start            (packet_start),
        .packet_protocol         (packet_protocol),
        .packet_len              (packet_len),
        .out_data                (out_data),
        .out_valid               (out_valid),
        .out_ready               (out_ready),
        .out_first               (out_first),
        .out_last                (out_last),
        .invalid_protocol_count  (invalid_protocol_count),
        .escape_error_count      (escape_error_count),
        .length_error_count      (length_error_count),
        .oversize_error_count    (oversize_error_count),
        .timeout_error_count     (timeout_error_count),
        .continuation_error_count(continuation_error_count)
    );
endmodule
`default_nettype wire
