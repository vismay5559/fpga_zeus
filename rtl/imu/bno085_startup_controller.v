`default_nettype none
// Configure the BNO085 as the sole SHTP host. Every SHTP write first obtains a
// fresh Buffer Status Notification, then the paced transmitter sends one token-
// consuming command. Valid reset notices invalidate configuration and restart it.
module bno085_startup_controller #(
    parameter integer CLK_HZ             = 100000000,
    parameter integer CLKS_PER_BIT       = 33,
    parameter integer TX_BYTE_GAP_US     = 120,
    parameter integer FEATURE_GAP_US     = 5000,
    parameter integer RESPONSE_TIMEOUT_US = 100000,
    parameter integer DEFAULT_BSN_TIMEOUT_MS = 100,
    parameter integer MAX_PACKET_BYTES   = 512
)(
    input  wire clk,
    input  wire rst,

    input  wire packet_start,
    input  wire [7:0] packet_protocol,
    input  wire [$clog2(MAX_PACKET_BYTES+1)-1:0] packet_len,
    input  wire [7:0] in_data,
    input  wire in_valid,
    output wire in_ready,
    input  wire in_first,
    input  wire in_last,

    output wire tx,
    output wire tx_busy,
    output reg configured,
    output wire configuring,
    output reg sensor_reset_pulse,
    output reg [31:0] sensor_reset_count,
    output reg [31:0] bsn_query_count,
    output reg [31:0] bsn_timeout_count,
    output reg [31:0] config_retry_count,
    output reg [31:0] confirmation_error_count,
    output reg [31:0] advertised_uart_timeout_ms,
    output reg rotation_confirmed,
    output reg accel_confirmed,
    output reg gyro_confirmed
);
    localparam integer CW = $clog2(MAX_PACKET_BYTES + 1);
    localparam integer AW = $clog2(MAX_PACKET_BYTES);
    localparam integer CLKS_PER_US_I = CLK_HZ / 1000000;
    localparam integer UW = (CLKS_PER_US_I <= 1) ? 1 : $clog2(CLKS_PER_US_I);
    localparam integer US_LAST_I = CLKS_PER_US_I - 1;
    localparam [UW-1:0] US_LAST = US_LAST_I[UW-1:0];
    localparam [CW-1:0] RX_MAX_COUNT = MAX_PACKET_BYTES[CW-1:0];

    localparam [2:0] RX_IDLE    = 3'd0;
    localparam [2:0] RX_RECEIVE = 3'd1;
    localparam [2:0] RX_PROCESS = 3'd2;
    localparam [2:0] RX_AD_SCAN = 3'd3;

    localparam [3:0] M_NEED_BSQ     = 4'd0;
    localparam [3:0] M_WAIT_BSQ     = 4'd1;
    localparam [3:0] M_WAIT_BSN     = 4'd2;
    localparam [3:0] M_SEND_COMMAND = 4'd3;
    localparam [3:0] M_WAIT_COMMAND = 4'd4;
    localparam [3:0] M_DELAY        = 4'd5;
    localparam [3:0] M_WAIT_ADVERT  = 4'd6;
    localparam [3:0] M_WAIT_CONFIRM = 4'd7;

    localparam [2:0] CMD_GET_ADVERT = 3'd0;
    localparam [2:0] CMD_SET_ROT    = 3'd1;
    localparam [2:0] CMD_SET_ACCEL  = 3'd2;
    localparam [2:0] CMD_SET_GYRO   = 3'd3;
    localparam [2:0] CMD_GET_ROT    = 3'd4;
    localparam [2:0] CMD_GET_ACCEL  = 3'd5;
    localparam [2:0] CMD_GET_GYRO   = 3'd6;

    localparam [7:0] REPORT_ROT   = 8'h05;
    localparam [7:0] REPORT_ACCEL = 8'h01;
    localparam [7:0] REPORT_GYRO  = 8'h02;

    reg [2:0] rx_state;
    reg [7:0] packet_mem [0:MAX_PACKET_BYTES-1];
    reg [CW-1:0] rx_count, rx_len, ad_scan_index;
    reg [7:0] rx_protocol;
    reg rx_stream_bad;

    reg rx_bsn_event, rx_advert_event, rx_reset_event;
    reg rx_feature_event, rx_timeout_tag_event;
    reg [15:0] rx_bsn_bytes;
    reg [7:0] rx_feature_id;
    reg [31:0] rx_feature_interval;
    reg [31:0] rx_timeout_ms;

    reg [3:0] main_state;
    reg [2:0] active_command;
    reg advertisement_seen;
    reg reset_episode_active;
    reg bsn_valid;
    reg [15:0] bsn_bytes;
    reg [31:0] bsn_age_us, bsn_timeout_us;
    reg [31:0] wait_us;

    reg [UW-1:0] us_divider;
    wire us_tick = (us_divider == US_LAST);

    wire tx_request_ready, tx_done;
    wire [$clog2(64+1)-1:0] tx_payload_index;
    reg [7:0] tx_payload_byte;
    reg [7:0] tx_channel;
    reg [6:0] tx_payload_len;
    wire tx_request_valid = (main_state == M_NEED_BSQ)
                         || (main_state == M_SEND_COMMAND);
    wire tx_request_bsq = (main_state == M_NEED_BSQ);
    wire [15:0] required_bsn_bytes = {9'd0, tx_payload_len} + 16'd4;
    wire [31:0] unused_tx_packets, unused_tx_bytes;
    wire [AW-1:0] ad_addr = ad_scan_index[AW-1:0];
    wire [7:0] ad_tag = packet_mem[ad_addr];
    wire [7:0] ad_size = packet_mem[ad_addr + 1'b1];
    wire [CW:0] ad_entry_end = {1'b0, ad_scan_index} + 2
                               + {{(CW-7){1'b0}}, ad_size};

    assign in_ready = (rx_state == RX_RECEIVE);
    assign configuring = !configured;

    function automatic [31:0] sat_inc;
        input [31:0] value;
        begin sat_inc = (&value) ? value : value + 1'b1; end
    endfunction

    // TODO 1 (implemented): command ROM. These bytes exactly encode the
    // STM32-matching 100 Hz Rotation Vector and 400 Hz accel/gyro profile.
    always @* begin
        tx_channel = (active_command == CMD_GET_ADVERT) ? 8'd0 : 8'd2;
        tx_payload_len = ((active_command == CMD_SET_ROT)
                       || (active_command == CMD_SET_ACCEL)
                       || (active_command == CMD_SET_GYRO)) ? 7'd17 : 7'd2;
        tx_payload_byte = 8'h00;
        case (active_command)
            CMD_GET_ADVERT: begin
                case (tx_payload_index)
                    0: tx_payload_byte = 8'h00;
                    1: tx_payload_byte = 8'h01;
                    default: tx_payload_byte = 8'h00;
                endcase
            end
            CMD_SET_ROT, CMD_SET_ACCEL, CMD_SET_GYRO: begin
                case (tx_payload_index)
                    0: tx_payload_byte = 8'hfd;
                    1: begin
                        case (active_command)
                            CMD_SET_ROT: tx_payload_byte = REPORT_ROT;
                            CMD_SET_ACCEL: tx_payload_byte = REPORT_ACCEL;
                            default: tx_payload_byte = REPORT_GYRO;
                        endcase
                    end
                    5: tx_payload_byte = (active_command == CMD_SET_ROT)
                                           ? 8'h10 : 8'hc4;
                    6: tx_payload_byte = (active_command == CMD_SET_ROT)
                                           ? 8'h27 : 8'h09;
                    default: tx_payload_byte = 8'h00;
                endcase
            end
            CMD_GET_ROT, CMD_GET_ACCEL, CMD_GET_GYRO: begin
                if (tx_payload_index == 0)
                    tx_payload_byte = 8'hfe;
                else if (tx_payload_index == 1) begin
                    case (active_command)
                        CMD_GET_ROT: tx_payload_byte = REPORT_ROT;
                        CMD_GET_ACCEL: tx_payload_byte = REPORT_ACCEL;
                        default: tx_payload_byte = REPORT_GYRO;
                    endcase
                end
            end
            default: tx_payload_byte = 8'h00;
        endcase
    end

    bno085_uart_packet_tx #(
        .CLK_HZ(CLK_HZ), .CLKS_PER_BIT(CLKS_PER_BIT),
        .TX_BYTE_GAP_US(TX_BYTE_GAP_US), .MAX_PAYLOAD(64)
    ) packet_tx (
        .clk(clk), .rst(rst),
        .request_valid(tx_request_valid), .request_ready(tx_request_ready),
        .request_bsq(tx_request_bsq), .request_channel(tx_channel),
        .request_payload_len(tx_payload_len), .payload_index(tx_payload_index),
        .payload_byte(tx_payload_byte), .tx(tx), .busy(tx_busy), .done(tx_done),
        .packet_count(unused_tx_packets), .wire_byte_count(unused_tx_bytes)
    );

    // TODO 2 (implemented): stage incoming validated packets and create simple
    // one-cycle events for BSN, advertisement, reset and Get Feature Response.
    always @(posedge clk) begin
        if (rst) begin
            rx_state <= RX_IDLE;
            rx_count <= {CW{1'b0}};
            rx_len <= {CW{1'b0}};
            ad_scan_index <= {CW{1'b0}};
            rx_protocol <= 8'd0;
            rx_stream_bad <= 1'b0;
            rx_bsn_event <= 1'b0;
            rx_advert_event <= 1'b0;
            rx_reset_event <= 1'b0;
            rx_feature_event <= 1'b0;
            rx_timeout_tag_event <= 1'b0;
            rx_bsn_bytes <= 16'd0;
            rx_feature_id <= 8'd0;
            rx_feature_interval <= 32'd0;
            rx_timeout_ms <= 32'd0;
        end else begin
            rx_bsn_event <= 1'b0;
            rx_advert_event <= 1'b0;
            rx_reset_event <= 1'b0;
            rx_feature_event <= 1'b0;
            rx_timeout_tag_event <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    if (packet_start) begin
                        rx_protocol <= packet_protocol;
                        rx_len <= packet_len;
                        rx_count <= {CW{1'b0}};
                        rx_stream_bad <= 1'b0;
                        if (packet_len != 0)
                            rx_state <= RX_RECEIVE;
                    end
                end
                RX_RECEIVE: begin
                    if (in_valid && in_ready) begin
                        if (rx_count < RX_MAX_COUNT)
                            packet_mem[rx_count[AW-1:0]] <= in_data;
                        else
                            rx_stream_bad <= 1'b1;
                        if (in_first != (rx_count == 0))
                            rx_stream_bad <= 1'b1;
                        if (in_last != (rx_count + 1'b1 == rx_len))
                            rx_stream_bad <= 1'b1;
                        rx_count <= rx_count + 1'b1;
                        if (in_last)
                            rx_state <= RX_PROCESS;
                    end
                end
                RX_PROCESS: begin
                    if (rx_stream_bad || (rx_count != rx_len)) begin
                        rx_state <= RX_IDLE;
                    end else if ((rx_protocol == 8'h00) && (rx_len == 2)) begin
                        rx_bsn_bytes <= {packet_mem[1], packet_mem[0]};
                        rx_bsn_event <= 1'b1;
                        rx_state <= RX_IDLE;
                    end else if ((rx_protocol == 8'h01) && (rx_len >= 5)) begin
                        if ((packet_mem[2] == 0) && (packet_mem[4] == 0)) begin
                            rx_advert_event <= 1'b1;
                            ad_scan_index <= 5;
                            rx_state <= RX_AD_SCAN;
                        end else if ((packet_mem[2] == 1)
                                     && (packet_mem[4] == 8'h01)) begin
                            rx_reset_event <= 1'b1;
                            rx_state <= RX_IDLE;
                        end else if ((packet_mem[2] == 2)
                                     && (packet_mem[4] == 8'hfc)
                                     && (rx_len >= 21)) begin
                            rx_feature_id <= packet_mem[5];
                            rx_feature_interval <= {packet_mem[12], packet_mem[11],
                                                    packet_mem[10], packet_mem[9]};
                            rx_feature_event <= 1'b1;
                            rx_state <= RX_IDLE;
                        end else begin
                            rx_state <= RX_IDLE;
                        end
                    end else begin
                        rx_state <= RX_IDLE;
                    end
                end
                RX_AD_SCAN: begin
                    if (ad_scan_index + 2 > rx_len) begin
                        rx_state <= RX_IDLE;
                    end else if (ad_entry_end > {1'b0, rx_len}) begin
                        rx_state <= RX_IDLE;
                    end else begin
                        if ((ad_tag == 8'h81)
                            && (ad_size == 4)) begin
                            rx_timeout_ms <= {packet_mem[ad_addr+5], packet_mem[ad_addr+4],
                                              packet_mem[ad_addr+3], packet_mem[ad_addr+2]};
                            rx_timeout_tag_event <= 1'b1;
                        end
                        ad_scan_index <= ad_entry_end[CW-1:0];
                    end
                end
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // TODO 3 (implemented): microsecond time base for BSN expiry, command
    // response timeouts and the STM32-compatible 5 ms feature-command pause.
    always @(posedge clk) begin
        if (rst)
            us_divider <= {UW{1'b0}};
        else if (us_tick)
            us_divider <= {UW{1'b0}};
        else
            us_divider <= us_divider + 1'b1;
    end

    // TODO 4 (implemented): obtain a fresh BSN before every SHTP write. A BSN
    // is consumed by one write and discarded if its advertised lifetime ends.
    always @(posedge clk) begin
        if (rst) begin
            main_state <= M_NEED_BSQ;
            active_command <= CMD_GET_ADVERT;
            advertisement_seen <= 1'b0;
            reset_episode_active <= 1'b0;
            bsn_valid <= 1'b0;
            bsn_bytes <= 16'd0;
            bsn_age_us <= 32'd0;
            bsn_timeout_us <= DEFAULT_BSN_TIMEOUT_MS * 1000;
            wait_us <= 32'd0;
            configured <= 1'b0;
            sensor_reset_pulse <= 1'b0;
            sensor_reset_count <= 32'd0;
            bsn_query_count <= 32'd0;
            bsn_timeout_count <= 32'd0;
            config_retry_count <= 32'd0;
            confirmation_error_count <= 32'd0;
            advertised_uart_timeout_ms <= DEFAULT_BSN_TIMEOUT_MS;
            rotation_confirmed <= 1'b0;
            accel_confirmed <= 1'b0;
            gyro_confirmed <= 1'b0;
        end else begin
            sensor_reset_pulse <= 1'b0;

            if (rx_timeout_tag_event && (rx_timeout_ms != 0)) begin
                advertised_uart_timeout_ms <= rx_timeout_ms;
                bsn_timeout_us <= (rx_timeout_ms << 10)
                                - (rx_timeout_ms << 4) - (rx_timeout_ms << 3);
            end

            if (rx_bsn_event) begin
                bsn_valid <= 1'b1;
                bsn_bytes <= rx_bsn_bytes;
                bsn_age_us <= 32'd0;
            end else if (us_tick && bsn_valid) begin
                if (bsn_age_us + 1'b1 >= bsn_timeout_us) begin
                    bsn_valid <= 1'b0;
                    bsn_timeout_count <= sat_inc(bsn_timeout_count);
                end else begin
                    bsn_age_us <= bsn_age_us + 1'b1;
                end
            end

            if (rx_advert_event) begin
                advertisement_seen <= 1'b1;
                if (!configured && (active_command == CMD_GET_ADVERT)) begin
                    active_command <= CMD_SET_ROT;
                    main_state <= M_NEED_BSQ;
                    wait_us <= 32'd0;
                end
            end

            // TODO 5 (implemented): a validated executable-channel reset
            // notice invalidates old configuration and starts one new episode.
            if (rx_reset_event) begin
                configured <= 1'b0;
                rotation_confirmed <= 1'b0;
                accel_confirmed <= 1'b0;
                gyro_confirmed <= 1'b0;
                bsn_valid <= 1'b0;
                active_command <= advertisement_seen ? CMD_SET_ROT : CMD_GET_ADVERT;
                main_state <= M_NEED_BSQ;
                wait_us <= 32'd0;
                if (!reset_episode_active) begin
                    reset_episode_active <= 1'b1;
                    sensor_reset_pulse <= 1'b1;
                    sensor_reset_count <= sat_inc(sensor_reset_count);
                end
            end else begin
                // TODO 6 (implemented): accept only exact interval confirmations.
                if (rx_feature_event) begin
                    case (rx_feature_id)
                        REPORT_ROT: begin
                            if (rx_feature_interval == 32'd10000)
                                rotation_confirmed <= 1'b1;
                            else
                                confirmation_error_count
                                    <= sat_inc(confirmation_error_count);
                        end
                        REPORT_ACCEL: begin
                            if (rx_feature_interval == 32'd2500)
                                accel_confirmed <= 1'b1;
                            else
                                confirmation_error_count
                                    <= sat_inc(confirmation_error_count);
                        end
                        REPORT_GYRO: begin
                            if (rx_feature_interval == 32'd2500)
                                gyro_confirmed <= 1'b1;
                            else
                                confirmation_error_count
                                    <= sat_inc(confirmation_error_count);
                        end
                        default: confirmation_error_count
                                   <= sat_inc(confirmation_error_count);
                    endcase
                end

                case (main_state)
                    M_NEED_BSQ: begin
                        if (tx_request_valid && tx_request_ready) begin
                            main_state <= M_WAIT_BSQ;
                            bsn_query_count <= sat_inc(bsn_query_count);
                        end
                    end
                    M_WAIT_BSQ: begin
                        if (tx_done) begin
                            main_state <= M_WAIT_BSN;
                            wait_us <= 32'd0;
                        end
                    end
                    M_WAIT_BSN: begin
                        if (bsn_valid && (bsn_bytes >= required_bsn_bytes)) begin
                            main_state <= M_SEND_COMMAND;
                        end else if (us_tick) begin
                            if (wait_us + 1'b1 >= RESPONSE_TIMEOUT_US) begin
                                wait_us <= 32'd0;
                                bsn_valid <= 1'b0;
                                bsn_timeout_count <= sat_inc(bsn_timeout_count);
                                main_state <= M_NEED_BSQ;
                            end else begin
                                wait_us <= wait_us + 1'b1;
                            end
                        end
                    end
                    M_SEND_COMMAND: begin
                        if (tx_request_valid && tx_request_ready) begin
                            bsn_valid <= 1'b0;
                            main_state <= M_WAIT_COMMAND;
                        end
                    end
                    M_WAIT_COMMAND: begin
                        if (tx_done) begin
                            wait_us <= 32'd0;
                            if (active_command == CMD_GET_ADVERT)
                                main_state <= M_WAIT_ADVERT;
                            else
                                main_state <= M_DELAY;
                        end
                    end
                    M_DELAY: begin
                        if (us_tick) begin
                            if (wait_us + 1'b1 >= FEATURE_GAP_US) begin
                                wait_us <= 32'd0;
                                case (active_command)
                                    CMD_SET_ROT: active_command <= CMD_SET_ACCEL;
                                    CMD_SET_ACCEL: active_command <= CMD_SET_GYRO;
                                    CMD_SET_GYRO: active_command <= CMD_GET_ROT;
                                    CMD_GET_ROT: active_command <= CMD_GET_ACCEL;
                                    CMD_GET_ACCEL: active_command <= CMD_GET_GYRO;
                                    default: active_command <= CMD_GET_GYRO;
                                endcase
                                if (active_command == CMD_GET_GYRO)
                                    main_state <= M_WAIT_CONFIRM;
                                else
                                    main_state <= M_NEED_BSQ;
                            end else begin
                                wait_us <= wait_us + 1'b1;
                            end
                        end
                    end
                    M_WAIT_ADVERT: begin
                        if (us_tick) begin
                            if (wait_us + 1'b1 >= RESPONSE_TIMEOUT_US) begin
                                wait_us <= 32'd0;
                                active_command <= CMD_GET_ADVERT;
                                main_state <= M_NEED_BSQ;
                            end else begin
                                wait_us <= wait_us + 1'b1;
                            end
                        end
                    end
                    M_WAIT_CONFIRM: begin
                        if (rotation_confirmed && accel_confirmed && gyro_confirmed) begin
                            configured <= 1'b1;
                            reset_episode_active <= 1'b0;
                        end else if (us_tick) begin
                            if (wait_us + 1'b1 >= RESPONSE_TIMEOUT_US) begin
                                wait_us <= 32'd0;
                                rotation_confirmed <= 1'b0;
                                accel_confirmed <= 1'b0;
                                gyro_confirmed <= 1'b0;
                                config_retry_count <= sat_inc(config_retry_count);
                                active_command <= CMD_SET_ROT;
                                main_state <= M_NEED_BSQ;
                            end else begin
                                wait_us <= wait_us + 1'b1;
                            end
                        end
                    end
                    default: main_state <= M_NEED_BSQ;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
