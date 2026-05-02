/**
 * Name:
 *   bp_me_cache_miss_tracker.sv
 *
 * Description:
 *   Observes a single bsg_cache bank's handshake signals to determine
 *   whether the current response required a DMA refill (cache miss).
 *   Relies on bsg_cache's blocking-per-bank property: at most one
 *   transaction is in flight at any time, so a single sticky bit
 *   unambiguously associates a DMA event with the outstanding request.
 *
 *   miss_o is valid and stable from the moment cache_data_v_i rises
 *   until cache_data_yumi_i is asserted.
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"

module bp_me_cache_miss_tracker
  (input  logic clk_i
  ,input  logic reset_i

  // bsg_cache handshake: request side
  ,input  logic cache_pkt_yumi_i   // cache accepted a new request
  // bsg_cache handshake: DMA side
  ,input  logic dma_pkt_v_i        // cache issued a DMA (miss occurred)
  // bsg_cache handshake: response side
  ,input  logic cache_data_v_i     // response data valid
  ,input  logic cache_data_yumi_i  // response data consumed

  // output: was the current response a cache miss?
  ,output logic miss_o
  );

  // Sticky bit: set when DMA fires, cleared when response is consumed.
  // Reset to 0 when a new request is accepted so back-to-back
  // transactions start clean.
  logic miss_r;

  always_ff @(posedge clk_i)
    if (reset_i)
      miss_r <= 1'b0;
    else if (cache_data_v_i & cache_data_yumi_i)
      miss_r <= 1'b0;          // transaction done, clear for next
    else if (dma_pkt_v_i)
      miss_r <= 1'b1;          // miss observed for in-flight request

  assign miss_o = miss_r | dma_pkt_v_i;  // combinationally include
                                          // same-cycle DMA assertion

endmodule
