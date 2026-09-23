`default_nettype none
// Complete BNO085 receive data path from asynchronous UART RX to retained IMU
// report registers. Configuration commands and TX flow control are separate.
module bno085_imu_rx #(
    parameter integer CLKS_PER_BIT      = 33,
    parameter integer FIFO_DEPTH       = 16,
    parameter integer MAX_PACKET_BYTES = 512,
    parameter integer TIMEOUT_CYCLES   = 1000000,
    parameter integer CLKS_PER_US      = 100
)(
    input wire clk,
    input wire rst,
    input wire rx,
    input wire snapshot,

    output wire signed [15:0] accel_x, accel_y, accel_z,
    output wire [4:0] accel_q_point,
    output wire [7:0] accel_report_sequence,
    output wire [1:0] accel_status,
    output wire [13:0] accel_delay,
    output wire [7:0] accel_shtp_sequence,
    output wire [63:0] accel_capture_us,
    output wire signed [31:0] accel_base_delta, accel_rebase_delta,
    output wire accel_base_valid, accel_has_sample, accel_new,

    output wire signed [15:0] gyro_x, gyro_y, gyro_z,
    output wire [4:0] gyro_q_point,
    output wire [7:0] gyro_report_sequence,
    output wire [1:0] gyro_status,
    output wire [13:0] gyro_delay,
    output wire [7:0] gyro_shtp_sequence,
    output wire [63:0] gyro_capture_us,
    output wire signed [31:0] gyro_base_delta, gyro_rebase_delta,
    output wire gyro_base_valid, gyro_has_sample, gyro_new,

    output wire signed [15:0] rotation_i, rotation_j,
    output wire signed [15:0] rotation_k, rotation_real,
    output wire [15:0] rotation_accuracy,
    output wire [4:0] rotation_q_point, rotation_accuracy_q_point,
    output wire [7:0] rotation_report_sequence,
    output wire [1:0] rotation_status,
    output wire [13:0] rotation_delay,
    output wire [7:0] rotation_shtp_sequence,
    output wire [63:0] rotation_capture_us,
    output wire signed [31:0] rotation_base_delta, rotation_rebase_delta,
    output wire rotation_base_valid, rotation_has_sample, rotation_new,

    output wire [31:0] uart_frame_error_count,
    output wire [31:0] fifo_overflow_count,
    output wire [31:0] invalid_protocol_count,
    output wire [31:0] escape_error_count,
    output wire [31:0] length_error_count,
    output wire [31:0] oversize_error_count,
    output wire [31:0] timeout_error_count,
    output wire [31:0] continuation_error_count,
    output wire [31:0] unsupported_report_count,
    output wire [31:0] packet_format_error_count,
    output wire [31:0] ignored_packet_count,
    output wire [31:0] shtp_sequence_gap_count,
    output wire [31:0] accel_sequence_gap_count,
    output wire [31:0] gyro_sequence_gap_count,
    output wire [31:0] rotation_sequence_gap_count
);
    wire packet_start;
    wire [7:0] packet_protocol;
    wire [$clog2(MAX_PACKET_BYTES+1)-1:0] packet_len;
    wire [63:0] packet_capture_us;
    wire [7:0] packet_data;
    wire packet_valid, packet_ready, packet_first, packet_last;
    wire [$clog2(FIFO_DEPTH+1)-1:0] unused_fifo_level;
    wire unused_fifo_full, unused_recovery_active;

    // TODO 1 (implemented): Physical UART through validated SHTP packets.
    bno085_uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT), .FIFO_DEPTH(FIFO_DEPTH),
        .MAX_PACKET_BYTES(MAX_PACKET_BYTES), .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .CLKS_PER_US(CLKS_PER_US)
    ) transport (
        .clk(clk), .rst(rst), .rx(rx),
        .packet_start(packet_start), .packet_protocol(packet_protocol),
        .packet_len(packet_len), .packet_capture_us(packet_capture_us),
        .out_data(packet_data), .out_valid(packet_valid),
        .out_ready(packet_ready), .out_first(packet_first), .out_last(packet_last),
        .fifo_level(unused_fifo_level), .fifo_full(unused_fifo_full),
        .recovery_active(unused_recovery_active),
        .uart_frame_error_count(uart_frame_error_count),
        .fifo_overflow_count(fifo_overflow_count),
        .invalid_protocol_count(invalid_protocol_count),
        .escape_error_count(escape_error_count), .length_error_count(length_error_count),
        .oversize_error_count(oversize_error_count), .timeout_error_count(timeout_error_count),
        .continuation_error_count(continuation_error_count)
    );

    // TODO 2 (implemented): Validated packet stream into atomic SH-2 report banks.
    sh2_report_parser #(.MAX_PACKET_BYTES(MAX_PACKET_BYTES)) reports (
        .clk(clk), .rst(rst), .snapshot(snapshot),
        .packet_start(packet_start), .packet_protocol(packet_protocol),
        .packet_len(packet_len), .packet_capture_us(packet_capture_us),
        .in_data(packet_data), .in_valid(packet_valid), .in_ready(packet_ready),
        .in_first(packet_first), .in_last(packet_last),

        .accel_x(accel_x), .accel_y(accel_y), .accel_z(accel_z),
        .accel_q_point(accel_q_point), .accel_report_sequence(accel_report_sequence),
        .accel_status(accel_status), .accel_delay(accel_delay),
        .accel_shtp_sequence(accel_shtp_sequence), .accel_capture_us(accel_capture_us),
        .accel_base_delta(accel_base_delta), .accel_rebase_delta(accel_rebase_delta),
        .accel_base_valid(accel_base_valid), .accel_has_sample(accel_has_sample),
        .accel_new(accel_new),

        .gyro_x(gyro_x), .gyro_y(gyro_y), .gyro_z(gyro_z),
        .gyro_q_point(gyro_q_point), .gyro_report_sequence(gyro_report_sequence),
        .gyro_status(gyro_status), .gyro_delay(gyro_delay),
        .gyro_shtp_sequence(gyro_shtp_sequence), .gyro_capture_us(gyro_capture_us),
        .gyro_base_delta(gyro_base_delta), .gyro_rebase_delta(gyro_rebase_delta),
        .gyro_base_valid(gyro_base_valid), .gyro_has_sample(gyro_has_sample),
        .gyro_new(gyro_new),

        .rotation_i(rotation_i), .rotation_j(rotation_j), .rotation_k(rotation_k),
        .rotation_real(rotation_real), .rotation_accuracy(rotation_accuracy),
        .rotation_q_point(rotation_q_point),
        .rotation_accuracy_q_point(rotation_accuracy_q_point),
        .rotation_report_sequence(rotation_report_sequence),
        .rotation_status(rotation_status), .rotation_delay(rotation_delay),
        .rotation_shtp_sequence(rotation_shtp_sequence),
        .rotation_capture_us(rotation_capture_us),
        .rotation_base_delta(rotation_base_delta),
        .rotation_rebase_delta(rotation_rebase_delta),
        .rotation_base_valid(rotation_base_valid),
        .rotation_has_sample(rotation_has_sample), .rotation_new(rotation_new),

        .unsupported_report_count(unsupported_report_count),
        .packet_format_error_count(packet_format_error_count),
        .ignored_packet_count(ignored_packet_count),
        .shtp_sequence_gap_count(shtp_sequence_gap_count),
        .accel_sequence_gap_count(accel_sequence_gap_count),
        .gyro_sequence_gap_count(gyro_sequence_gap_count),
        .rotation_sequence_gap_count(rotation_sequence_gap_count)
    );
endmodule
`default_nettype wire
