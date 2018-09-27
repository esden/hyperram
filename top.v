`default_nettype none
`include "baudgen.vh"

module top (
    input  clk,
    // dram pins
    inout [7:0] dram_dq,
    inout dram_rwds,
    output dram_ck,
    output dram_rst_l,
    output dram_cs_l,

    //output [4:0] dram_debug,

    input rx,
    output tx,

    // leds
    output [4:0] leds


);

    wire hram_clk = clk;
    reg reset = 1;
    wire nreset = ~ reset;

    always @(posedge hram_clk)
        reset <= 0;

    wire [7:0] data_pins_in;
    wire [7:0] data_pins_out;
    wire dram_dq_oe_l;


    // signals for hyper ram
    wire rd_rdy;
    reg rd_req = 0;
    reg wr_req = 0;
    reg [31:0] addr = 0;
    reg [31:0] wr_d;
    wire [31:0] rd_d;
    wire busy;
    reg mem_or_reg = 0;

    reg [3:0] wr_byte_en = 4'hF;        // write 4 bytes
    reg [5:0] rd_num_dwords = 6'h1;     // read 1 4 byte word

    reg [7:0] latency_1x = 8'h12;       // latency setup - not so important for 12mhz clock
    reg [7:0] latency_2x = 8'h16;

    // latch data when it's ready
    reg [31:0] ram_data;
    always @(posedge hram_clk)
      if(rd_rdy)
        ram_data <= rd_d;
    
    // setup inout lines for data and rwds pins
    SB_IO #(
        .PIN_TYPE(6'b 1010_01),
    ) hyperram_data_pins [7:0] (
        .PACKAGE_PIN(dram_dq),
        .OUTPUT_ENABLE(~dram_dq_oe_l),
        .D_OUT_0(data_pins_out),
        .D_IN_0(data_pins_in),
    );

    wire dram_rwds_out;
    wire dram_rwds_in;
    wire dram_rwds_oe_l;

    SB_IO #(
        .PIN_TYPE(6'b 1010_01),
    ) hyperram_rwds (
        .PACKAGE_PIN(dram_rwds),
        .OUTPUT_ENABLE(~dram_rwds_oe_l),
        .D_OUT_0(dram_rwds_out),
        .D_IN_0(dram_rwds_in),
    );

    // instantiate
    hyper_xface hyper_xface_0(.reset(reset), .clk(hram_clk),
    .rd_req(rd_req),
    .wr_req(wr_req),
    .wr_d(wr_d),
    .rd_d(rd_d),
    .rd_rdy(rd_rdy),
    .wr_byte_en(wr_byte_en),
    .rd_num_dwords(rd_num_dwords),
    .addr(addr),
    .busy(busy),


    .latency_1x(latency_1x),
    .latency_2x(latency_2x),
    .mem_or_reg(mem_or_reg),

    // pins
    .dram_dq_in(data_pins_in), .dram_dq_out(data_pins_out), .dram_dq_oe_l(dram_dq_oe_l),
    .dram_rwds_in(dram_rwds_in), .dram_rwds_out(dram_rwds_out), .dram_rwds_oe_l(dram_rwds_oe_l),
    .dram_ck(dram_ck),
    .dram_rst_l(dram_rst_l),
    .dram_cs_l(dram_cs_l));

    // serial port setup
    localparam BAUD = `B115200;

    wire rcv;
    wire tx_strb;
    wire [7:0] rxdata;
    wire [7:0] txdata;
    wire ready;
    wire logic_ce;

    reg [39:0] rx_reg = 0;
    reg [31:0] tx_reg = 0;
    reg [2:0] rx_byte_cnt = 0;
    reg [31:0] count = 0;

    // instantiate rx and tx
    uart_rx #(.BAUD(BAUD)) RX0 (.clk(hram_clk),
           .rstn(nreset),
           .rx(rx),
           .rcv(rcv),
           .data(rxdata)
          );

    uart_tx #(.BAUD(BAUD)) TX0 ( .clk(hram_clk),
             .rstn(nreset),
             .start(tx_strb),
             .data(txdata),
             .tx(tx),
             .ready(ready)
           );

  // debug output on leds
  assign leds = addr;

  // state machine states
  localparam ADDR = 8'h1;
  localparam LOAD = 8'h2;
  localparam WRITE = 8'h3;
  localparam READ = 8'h4;
  localparam READ_REQ = 8'h5;
  localparam COUNT = 8'h6;
  localparam CONST = 8'h7;


  // convenience buses for cmd and data bytes
  wire [7:0] cmd_byte = rx_reg[39:32];
  wire [31:0] data_bytes = rx_reg[31:0];

  // bytes waiting to send
  reg [2:0] tx_bytes = 0;

  // need a delay between starting serial and it toggling the busy pin
  reg last_ready = 0;
  always @(posedge clk)
    last_ready <= ready;

  // serial interface
  // waits for 5 data bytes and 1 end byte
  // first byte is a command (see above), second 4 make up an unsigned integer
  always @(posedge hram_clk) begin
    if (rcv) begin
        rx_reg <= {rx_reg[31:0], rxdata};
        rx_byte_cnt <= rx_byte_cnt + 1;
        if(rx_byte_cnt == 5) begin
            case(cmd_byte)
                ADDR:  begin addr <= data_bytes; tx_reg <= data_bytes; end
                LOAD:  begin wr_d <= data_bytes; tx_reg <= data_bytes; end
                WRITE: begin wr_req <= 1; tx_reg <= WRITE; end
                READ:  tx_reg <= ram_data;
                READ_REQ: begin rd_req <= 1; tx_reg <= READ_REQ; end
                COUNT: begin tx_reg <= count; count <= count + 1; end
                CONST: tx_reg <= 32'd259;
                default: tx_reg <= count;
            endcase
            rx_byte_cnt <= 0;
            // only want 4, but couldn't get it to work, so read an extra in the control program
            tx_bytes <= 5;
        end
    end else begin
        rd_req <= 0;
        wr_req <= 0;
    end

    // if a command is received, the tx data is queued in tx_reg
    // so while there are bytes to send, send each one
    if (tx_bytes > 0 )begin
        if(ready) begin
            tx_strb <= 1'b1;
            txdata <= tx_reg[31:24]; 
        // tx_uart takes 2 clock cycles for ready to go low after starting, so have to only do this on transition
        end else if (~ready && last_ready) begin
            tx_reg <= tx_reg << 8;
            tx_bytes <= tx_bytes - 1;
        end 
    end else
        tx_strb <= 1'b0;

  end
            
endmodule
