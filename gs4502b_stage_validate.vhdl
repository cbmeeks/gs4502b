-- This CPU pipeline stage checks if the instruction delivered from the cache
-- is in fact the instruction that we want to run, and that all required resources
-- are free.
--
-- To do this, it must remember the resources required by the most recent
-- instruction, as well as check for any undelivered results.
--
-- The intention is that memory reads into registers will result in a lock
-- being placed on the register in question.  This stage reads those locks,
-- together with looking at the resources required in this instruction, and
-- if the instruction would depend on any unavailable resource, then it will
-- hold the instruction and stall the pipeline.  Alternatively, if the CPU
-- diverts control away, or if the address from the instruction cache otherwise
-- does not match the signature of the one that has been requested, then the
-- candidate instruction is discarded, and the instruction_ready signal is not
-- asserted, thus causing the execute stage of the pipeline to idle.
--
-- While most instructions can occupy the execute state for a single cycle,
-- there are a few exceptions that we will have to handle.  The ones that
-- spring to mind are JSR, BSR, RTS and RTI, which all require placing or
-- retrieving more than one value on/off the stack, and in the case of the
-- return instruction, must block the pipeline until the new program counter
-- value is available.
--
-- Another job of this stage is to detect cache misses, i.e., when the correct
-- instruction cache line is present, but does not contain the correct
-- instruction.  In such cases we must ask the memory controller to fetch the
-- instruction in question (and which will then begin speculatively fetching
-- further instructions in that sequence as memory bandwidth allows).
--
-- The memory controller is rather intelligent in this processor, being
-- responsible for the operation of the read-modify-write instructions (thus
-- allowing the CPU to continue on to execute further instructions while they
-- are being processed, and also reducing the round-trip latency that would
-- otherwise be incurred through the pipeline to read and write the address in
-- question.  This approach is necessary because addressing modes will only be
-- resolved in the memory controller, and since many addressing modes depend on
-- the value of index registers, the target address cannot be computed until
-- the correct register values are available, which in turn requires that there
-- are no instructions ahead of it in the pipeline, as those could mutate the
-- index values.
--
-- If there are no uncommited instructions that would affect the destination of
-- a branch, conditional branch instructions can be patched to present the correct
-- expected pc, and have their conditional flags stripped, thus reducing them
-- to unconditional branches

use WORK.ALL;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;
use work.icachetypes.all;

entity gs4502b_stage_validate is
  port (
    cpuclock : in std_logic;
    
-- Input: translated address of instruction in memory
    instruction_address_in : in unsigned(31 downto 0);
-- Input: 3 instruction bytes
    instruction_bytes_in : in std_logic_vector(23 downto 0);
-- Input: 8-bit PCH (PC upper byte) for this instruction
    pch_in : in unsigned(15 downto 8);
-- Input: translated 32-bit PC for expected case
    pc_expected_in : in unsigned(31 downto 0);
-- Input: translated 32-bit PC for branch mis-predict case
    pc_mispredict_in : in unsigned(31 downto 0);
-- Input: 1-bit Branch prediction flag: 1=assume take branch
    branch_predict_in : in std_logic;
-- Input: What resources does this instruction require and modify?
    resources_required_in : in instruction_resources;
    resources_modified_in : in instruction_resources;
    instruction_information_in : in instruction_information;
        
-- Is the instruction pipeline stalled?
    stall_in : in std_logic;
-- What resources have just been locked by the execute stage?
    resources_freshly_locked_by_execute_stage : in instruction_resources;
    resource_lock_transaction_id_in : in transaction_id;
    resource_lock_transaction_valid_in : boolean;

-- What can we see from the memory controller?
    completed_transaction : in transaction_result; 

-- Output: 32-bit address source of instruction
    instruction_address_out : out unsigned(31 downto 0);
-- Output: 3 instruction bytes
    instruction_bytes_out : out std_logic_vector(23 downto 0);
-- Output: 8-bit PCH (PC upper byte) for this instruction
    pch_out : out unsigned(15 downto 8);
-- Output: Translated PC for expected case
    pc_expected_translated : out unsigned(31 downto 0);
-- Output: 16-bit PC for branch mis-predict case
    pc_mispredict_translated : out unsigned(31 downto 0);
-- Output: Instruction decode signals that can be computed
-- Output: 1-bit Branch prediction flag: 1=assume take branch
--         (for passing to MMU if branch prediction is wrong, so that cache
--         line can be updated).
    branch_predict_out : out std_logic;
-- Output: Boolean: Is the instruction we have here ready for execution
-- (including that the pipeline is not stalled)
    instruction_valid : out std_logic;
-- Output: What resources does this instruction require and modify?
    resources_required_out : out instruction_resources;
    resources_modified_out : out instruction_resources;
    instruction_information_out : out instruction_information;

-- Output: Stall signal to tell pipeline behind us to wait
    stall_out : out std_logic
    
    );
end gs4502b_stage_validate;

architecture behavioural of gs4502b_stage_validate is

  -- Resources that can be modified or required by a given instruction
  signal resources_about_to_be_locked_by_execute_stage : instruction_resources := (others => false);

  -- Register and flag renaming
  signal reg_a_name : transaction_id;
  signal reg_x_name : transaction_id;
  signal reg_b_name : transaction_id;
  signal reg_y_name : transaction_id;
  signal reg_z_name : transaction_id;
  signal reg_spl_name : transaction_id;
  signal reg_sph_name : transaction_id;
  signal flag_z_name : transaction_id;
  signal flag_c_name : transaction_id;
  signal flag_v_name : transaction_id;
  signal flag_n_name : transaction_id;
  
  -- Resources that we are still waiting to clear following memory accesses.
  -- XXX Implement logic to update this
  signal resources_what_will_still_be_outstanding_next_cycle : instruction_resources := (others => false);
  
  -- Stall buffer and stall logic
  signal stall_buffer_occupied : std_logic := '0';
  signal stall_out_current : std_logic := '0';  
  signal stalled_instruction_address : unsigned(31 downto 0);
  signal stalled_instruction_bytes : std_logic_vector(23 downto 0);
  signal stalled_instruction_information : instruction_information;
  signal stalled_pch : unsigned(15 downto 8);
  signal stalled_pc_expected : unsigned(15 downto 0);
  signal stalled_pc_mispredict : unsigned(15 downto 0);
  signal stalled_branch_predict : std_logic;
  signal stalled_resources_required : instruction_resources;
  signal stalled_resources_modified : instruction_resources;
  
begin

  process(cpuclock)
    variable next_line : unsigned(9 downto 0);

    -- MUX variables to choose between stall buffer and incoming instruction
    variable instruction_address : unsigned(31 downto 0);
    variable instruction_bytes : std_logic_vector(23 downto 0);
    variable pch : unsigned(15 downto 8);
    variable pc_expected : unsigned(15 downto 0);
    variable pc_mispredict : unsigned(15 downto 0);
    variable branch_predict : std_logic;
    variable resources_modified : instruction_resources;
    variable resources_required : instruction_resources;
    variable instruction_information : instruction_information;
  begin
    if (rising_edge(cpuclock)) then

      -- Watch for memory transactions coming in, so that we can commit and
      -- unlock registers and flags as required.
      -- XXX Don't modify resources that will be also modified by the execute
      -- stage this cycle.
      if completed_transaction_valid = true then
        if completed_transaction_id = reg_a_name then
          -- Must happen same cycle in execute: reg_a <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.reg_a <= false;
        end if;
        if completed_transaction_id = reg_b_name then
          -- Must happen same cycle in execute: reg_b <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.reg_b <= false;
        end if;
        if completed_transaction_id = reg_x_name then
          -- Must happen same cycle in execute: reg_x <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.reg_x <= false;
        end if;
        if completed_transaction_id = reg_y_name then
          -- Must happen same cycle in execute: reg_y <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.reg_y <= false;
        end if;
        if completed_transaction_id = reg_z_name then
          -- Must happen same cycle in execute: reg_z <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.reg_z <= false;
        end if;
        if completed_transaction_id = flag_z_name then
          -- Must happen same cycle in execute: flag_z <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.flag_z <= false;
        end if;
        if completed_transaction_id = flag_c_name then
          -- Must happen same cycle in execute: flag_c <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.flag_c <= false;
        end if;
        if completed_transaction_id = flag_n_name then
          -- Must happen same cycle in execute: flag_n <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.flag_n <= false;
        end if;
        if completed_transaction_id = flag_v_name then
          -- Must happen same cycle in execute: flag_v <= completed_transaction_value;
          resources_what_will_still_be_outstanding_next_cycle.flag_v <= false;
        end if;
      end if;
      
      -- Watch for transaction announcements from execute stage so that we can
      -- rename registers and flags as required.
      -- This must come after the above, so that new locks take priority over
      -- retiring old instructions.
      if resource_lock_transaction_valid_in = true then
        if resources_freshly_locked_by_execute_stage.reg_a then
          reg_a_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.reg_a <= true;
        end if;
        if resources_freshly_locked_by_execute_stage.reg_b then
          reg_b_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.reg_b <= true;
        end if;
        if resources_freshly_locked_by_execute_stage.reg_x then
          reg_x_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.reg_x <= true;
        end if;
        if resources_freshly_locked_by_execute_stage.reg_y then
          reg_y_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.reg_y <= true;
        end if;
        if resources_freshly_locked_by_execute_stage.reg_z then
          reg_z_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.reg_z <= true;
        end if;
        if resources_freshly_locked_by_execute_stage.flag_z then
          flag_z_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.flag_z <= true;
        end if;
        if resources_freshly_locked_by_execute_stage.flag_c then
          flag_c_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.flag_c <= true;
        end if;
        if resources_freshly_locked_by_execute_stage.flag_v then
          flag_v_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.flag_v <= true;
        end if;
        if resources_freshly_locked_by_execute_stage.flag_n then
          flag_n_name <= resource_lock_transaction_id_in;
          resources_what_will_still_be_outstanding_next_cycle.flag_n
            <= true;
        end if;
      end if;
      
      -- We are stalled unless we are processing something we are reading in,
      -- and we are not being asked to stall ourselves.
      stall_out <= '1';
      
      if stall_in='0' then
        -- Downstream stage is willing to accept an instruction
        
        if stall_buffer_occupied = '1' then
          -- Pass instruction from our stall buffer
          instruction_address := stalled_instruction_address;
          instruction_bytes := stalled_instruction_bytes;
          pch := stalled_pch;
          branch_predict := stalled_branch_predict;
          resources_modified := stalled_resources_modified;
          resources_required := stalled_resources_required;
          instruction_information := stalled_instruction_information;
        else
          instruction_address := instruction_address_in;
          instruction_bytes := instruction_bytes_in;
          pch := pch_in;
          branch_predict := branch_predict_in;
          resources_modified := resources_modified_in;
          resources_required := resources_required_in;
          instruction_information := instruction_information_in;
          
          -- Reading from pipeline input, and we are not stalled, so we can tell
          -- the upstream pipeline stage to resume
          stall_out <= '0';
          stall_out_current <= '0';
        end if;

        -- In either case above, the stall buffer becomes empty
        stall_buffer_occupied <= '0';
        
        -- Pass signals through
        instruction_address_out <= instruction_address;
        instruction_bytes_out <= instruction_bytes;
        pch_out <= pch;
        branch_predict_out <= branch_predict;
        resources_modified_out <= resources_modified;
        resources_required_out <= resources_required;
        instruction_information_out <= instruction_information;

        -- Remember resources that will be potentially modified by any
        -- instructions that have not yet passed the execute stage.
        -- At the moment, the execute stage is the stage immediately
        -- following this one, so we need only remember the one instruction.
        -- XXX This memory needs to expand to multiple instructions if the
        -- pipeline becomes deeper.
        -- More specifically, we only care about resources which will be
        -- modified by this instruction following a memory access, as immediate
        -- mode, register indexing etc will all happen during the execute
        -- cycle, and so be available.  Therefore only memory load or
        -- read-modify-write instructions are a problem here.  Thus, if the
        -- instruction is a load (including stack pop) or RMW, then we need to note the
        -- resources as being delayed. In all other cases we have no
        -- delayed resources
        if instruction_information.does_load=true then
          -- Set delayed flag for all resources modified by this
          -- instruction.
          -- XXX We can probably optimise this a bit, by not setting SPL
          -- delayed for a stack operation, for example, because the value
          -- of SP will be resolved. But we can worry about that later.
          resources_about_to_be_locked_by_execute_stage <= resources_modified;
        else
          -- Set delayed flag for all resources to false
          resources_about_to_be_locked_by_execute_stage <= (others => false);
        end if;
        
        if
          -- Are all the resources we need here?
          --
          -- All that we care about are those resources which will not be available
          -- next cycle because they are either currently locked, or are about
          -- to be locked because the most recent instruction requires a memory
          -- access to resolve them, e.g, following a non-immediate mode ALU
          -- operation. e.g., EOR $1234 / STA $2345 would require the STA to
          -- stall until the EOR operation completes. 
          -- 
          -- (We also want to implement short-cutting register access when
          -- registers are pending being loaded from memory. This basically consists
          -- of using the memory transaction ID for a load as the source for
          -- the store operation, instead of the register, when the operation is
          -- passed to the memory controller (stores don't affect CPU flags),
          -- so we can ignore that for now.)
          --
          -- Therefore what we need to test now is whether we decided that the
          -- previous instruction will block on a memory access. If yes, then
          -- we need to hold this instruction.
          --
          -- We also have to check outstanding_resources, which is the list of
          -- resources for which we are currently waiting for finalisation from
          -- the memory controller, i.e., due to resolution of renamed
          -- registers or flags.  Outstanding resources is computed by seeing
          -- what transaction information the execute stage informs us of (it
          -- is the stage that allocates transaction IDs to memory
          -- transactions, and hence does the resource re-writing.

          -- Currently locked instructions are easy to test
          not_empty(resources_required and resources_about_to_be_locked_by_execute_stage)
          or not_empty(resources_required and resources_what_will_still_be_outstanding_next_cycle)
          or not_empty(resources_required and resources_freshly_locked_by_execute_stage)
        then
          -- Instructions resource requirements not currently met.
          -- XXX - HOLD INPUT *and* OUTPUT values
          -- What would be really nice is if we can insert bubbles in the
          -- pipeline to be closed up when we get here, so that we can avoid
          -- the need for any extra buffer registers and muxes.

          -- Tell downstream stage the instruction is not valid for execution.
          instruction_valid <= '0';

          -- Tell upstream stage that we are stalled
          stall_out <= '1';
          stall_out_current <= '1';

          -- If we weren't already stalling the upstream, then we need to
          -- copy the current inputs to the stall buffer, and mark the stall
          -- buffer as occupied.
          if stall_out_current='0' then
            stalled_instruction_address <= instruction_address;
            stalled_instruction_bytes <= instruction_bytes;
            stalled_pch <= pch;
            stalled_branch_predict <= branch_predict;
            stalled_resources_modified <= resources_modified;
            stalled_resources_required <= resources_required;
            stalled_instruction_information <= instruction_information;
            stall_buffer_occupied <= '1';
          end if;
        else
          -- Instruction meets all requirements
          -- Release and pass forward
          instruction_valid <= '1';
        end if;
      else
        -- Pipeline stalled: hold existing values.
        -- XXX: We should assign them so that we avoid having flip-flops.        
        instruction_valid <= '0';        
      end if;

    end if;    
  end process;    
      
end behavioural;
