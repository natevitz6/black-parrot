/**
 *
 * Name:
 *   bp_uce_prefetcher.sv
 *
 * Description:
 *   This is the UCE side L2 prefetch request generator
 *
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"

module bp_uce_prefetcher
  import bp_common_pkg::*;
  import bp_me_pkg::*;
  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    , parameter addr_width_p = "inv"
    , parameter block_offset_width_p = "inv"
    , parameter miss_count = "inv"
    , parameter lookahead_depth = "inv"
    )
   (input clk_i
     , input reset_i

     , input req_v_i
     , input miss_i
     , input [addr_width_p-1:0] miss_addr_i

     , output logic prefetch_v_o
     , output logic [addr_width_p-1:0] prefetch_addr_o
     , input prefetch_yumi_i
    );

  localparam logic [addr_width_p-1:0] line_size_lp =
    (addr_width_p'(1) << block_offset_width_p);

  logic prefetch_v_r, prefetch_v_n;
  logic stream_active_r, stream_active_n;

  logic [$clog2(lookahead_depth+1)-1:0] remaining_prefetches_r;
  logic [$clog2(lookahead_depth+1)-1:0] remaining_prefetches_n;

  logic [1:0] count_r, count_n;

  logic [addr_width_p-1:0] prefetch_addr_r, prefetch_addr_n;
  logic [addr_width_p-1:0] expected_miss_addr_r, expected_miss_addr_n;

  // Registered miss observation stage
  logic miss_v_r, miss_v_n;
  logic [addr_width_p-1:0] miss_addr_r, miss_addr_n;
  logic [addr_width_p-1:0] miss_next_addr_r, miss_next_addr_n;

  assign prefetch_addr_o = prefetch_addr_r;
  assign prefetch_v_o    = prefetch_v_r;

  always_comb begin
    prefetch_v_n            = prefetch_v_r;
    prefetch_addr_n         = prefetch_addr_r;
    count_n                 = count_r;
    stream_active_n         = stream_active_r;
    remaining_prefetches_n  = remaining_prefetches_r;
    expected_miss_addr_n    = expected_miss_addr_r;

    miss_v_n                = req_v_i & miss_i;
    miss_addr_n             = miss_addr_r;
    miss_next_addr_n        = miss_next_addr_r;

    if (req_v_i & miss_i) begin
      miss_addr_n      = miss_addr_i;
      miss_next_addr_n = miss_addr_i + line_size_lp;
    end

    // Advance currently-issued prefetch stream when accepted
    if (prefetch_yumi_i) begin
      prefetch_addr_n      = prefetch_addr_r + line_size_lp;
      expected_miss_addr_n = expected_miss_addr_r + line_size_lp;

      if (remaining_prefetches_r == '0) begin
        prefetch_v_n = 1'b0;
      end
      else begin
        remaining_prefetches_n = remaining_prefetches_r - 1'b1;
      end
    end

    // Train / start stream from the registered miss from the previous cycle
    if (miss_v_r) begin
      if (miss_count == 1) begin
        prefetch_addr_n = miss_next_addr_r;
        prefetch_v_n    = 1'b1;
      end
      else if (miss_addr_r == expected_miss_addr_r) begin
        if (count_r == miss_count) begin
          remaining_prefetches_n = lookahead_depth;
          prefetch_addr_n        = miss_next_addr_r;
          expected_miss_addr_n   = miss_next_addr_r;
          prefetch_v_n           = 1'b1;
          stream_active_n        = 1'b1;
        end
        else begin
          expected_miss_addr_n = miss_next_addr_r;
          count_n              = count_r + 2'd1;
        end
      end
      else begin
        stream_active_n        = 1'b0;
        remaining_prefetches_n = '0;
        expected_miss_addr_n   = miss_next_addr_r;
        prefetch_v_n           = 1'b0;
        count_n                = 2'd1;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      prefetch_v_r           <= 1'b0;
      prefetch_addr_r        <= '0;
      count_r                <= '0;
      stream_active_r        <= '0;
      remaining_prefetches_r <= '0;
      expected_miss_addr_r   <= '0;

      miss_v_r               <= 1'b0;
      miss_addr_r            <= '0;
      miss_next_addr_r       <= '0;
    end
    else begin
      prefetch_v_r           <= prefetch_v_n;
      prefetch_addr_r        <= prefetch_addr_n;
      count_r                <= count_n;
      stream_active_r        <= stream_active_n;
      remaining_prefetches_r <= remaining_prefetches_n;
      expected_miss_addr_r   <= expected_miss_addr_n;

      miss_v_r               <= miss_v_n;
      miss_addr_r            <= miss_addr_n;
      miss_next_addr_r       <= miss_next_addr_n;
/*
`ifndef SYNTHESIS
      if (miss_v_r) begin
        $display("[PREF-TRAIN] time=%0t miss_addr=%h expected=%h count=%0d active=%0b p_v=%0b p_addr=%h rem=%0d",
                 $time, miss_addr_r, expected_miss_addr_r, count_r,
                 stream_active_r, prefetch_v_r, prefetch_addr_r, remaining_prefetches_r);
      end

      if (miss_v_r && (miss_addr_r == expected_miss_addr_r) && (count_r == miss_count) && !stream_active_r) begin
        $display("[PREF-STREAM-START] time=%0t miss_addr=%h prefetch_addr=%h rem=%0d",
                 $time, miss_addr_r, miss_next_addr_r, lookahead_depth);
      end

      if (miss_v_r && (miss_addr_r != expected_miss_addr_r)) begin
        $display("[PREF-MISMATCH] time=%0t miss_addr=%h expected=%h old_count=%0d active=%0b",
                 $time, miss_addr_r, expected_miss_addr_r, count_r, stream_active_r);
      end

      if (prefetch_yumi_i) begin
        $display("[PREF-YUMI] time=%0t addr=%h rem_before=%0d active=%0b",
                 $time, prefetch_addr_r, remaining_prefetches_r, stream_active_r);
      end
`endif
*/
    end
  end

endmodule