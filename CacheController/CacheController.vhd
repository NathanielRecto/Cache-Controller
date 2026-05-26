library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity CacheController is
    Port ( clk 	      : in  STD_LOGIC;
			ADDR 	  : out  STD_LOGIC_VECTOR(15 downto 0);
			DOUT 	  : out  STD_LOGIC_VECTOR(7 downto 0);
			sAddra    : out  STD_LOGIC_VECTOR(7 downto 0);
			sDina     : out  STD_LOGIC_VECTOR(7 downto 0);
			sDouta    : out  STD_LOGIC_VECTOR(7 downto 0);
			sD_Addra  : out  STD_LOGIC_VECTOR(15 downto 0);
			sD_Dina   : out  STD_LOGIC_VECTOR(7 downto 0);
			sD_Douta  : out  STD_LOGIC_VECTOR(7 downto 0);
			cacheAddr : out  STD_LOGIC_VECTOR(7 downto 0);
            WR_RD, MEMSTRB, RDY ,CS	: out  STD_LOGIC);
end CacheController;

architecture Behavioral of CacheController is
--CPU Signals
	signal CPU_Dout, CPU_Din		: STD_LOGIC_VECTOR(7 downto 0);
	signal CPU_ADD 				: STD_LOGIC_VECTOR (15 downto 0);
	signal CPU_W_R,CPU_CS 			: STD_LOGIC;
	signal CPU_RDY					: STD_LOGIC;
	signal cpu_tag				              : STD_LOGIC_VECTOR(7 downto 0);
	signal index				              : STD_LOGIC_VECTOR(2 downto 0);
	signal offset		                   	              : STD_LOGIC_VECTOR(4 downto 0);
	signal Tag_index					: STD_LOGIC_VECTOR(10 downto 0);
	
--SRAM(cache memory) Signals
	signal Dbit				: STD_LOGIC_VECTOR(7 downto 0):= "00000000";
	signal Vbit				: STD_LOGIC_VECTOR(7 downto 0):= "00000000";
	signal sADD, sDin, sDout 		: STD_LOGIC_VECTOR(7 downto 0);
	signal sWen				: STD_LOGIC_VECTOR(0 DOWNTO 0);
	signal TAGWen				: STD_LOGIC := '0';
	
--SDRAM Signals
	signal SDRAM_Din,SDRAM_Dout	: STD_LOGIC_VECTOR(7 downto 0);
	signal SDRAM_ADD					: STD_LOGIC_VECTOR(15 downto 0);
	signal SDRAM_MSTRB,SDRAM_W_R	: STD_LOGIC;
	signal counter						: integer := 0;
	signal sdoffset					: integer := 0;
	signal victim_tag				: std_logic_vector (7 downto 0):= (others => '0');
	signal victim_index			: std_logic_vector (2 downto 0) := (others => '0');

--SRAM array
type cachememory is array (7 downto 0) of STD_LOGIC_VECTOR(7 downto 0);
		signal memtag: cachememory := ((others=> (others=>'0')));

--ICON & VIO  & ILA Signals 
	signal control0 : STD_LOGIC_VECTOR(35 downto 0);
	signal ila_data : std_logic_vector(99 downto 0);
	signal trig0 	: std_logic_vector(0 TO 0);

--State Signals
	--Hit/Miss			            --0000 : state0
	--Load from Main Memory 	   --0001 : state1
	--Write back to Main Memory	--0010 : state2
	--IDLE 					     	   --0011 : state3
	--READY 					         --0100 : state4
	
	TYPE state_value IS (state4, state0, state1, state2, state3);
	signal state_current			: state_value ;
	signal state 					: STD_LOGIC_VECTOR(3 downto 0);
	
--Components
	COMPONENT SDRAMController 
    Port ( 
		clk								: in  STD_LOGIC;
		ADDR 								: in  STD_LOGIC_VECTOR (15 downto 0);
      WR_RD 						: in  STD_LOGIC;
      MEMSTRB 						: in  STD_LOGIC;
      DIN 							: in  STD_LOGIC_VECTOR (7 downto 0);
      DOUT 						: out STD_LOGIC_VECTOR (7 downto 0));
	END COMPONENT;
	
	COMPONENT SRAM
	PORT (
    clka 							: IN STD_LOGIC;
    wea 							: IN STD_LOGIC_VECTOR(0 DOWNTO 0);
    addra 						: IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    dina 							: IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    douta 						: OUT STD_LOGIC_VECTOR(7 DOWNTO 0));
	END COMPONENT;
	
	COMPONENT CPU_gen 
	Port ( 
		clk 								: in  STD_LOGIC;
      rst 								: in  STD_LOGIC;
      trig 								: in  STD_LOGIC;
      Address 						: out STD_LOGIC_VECTOR (15 downto 0);
      wr_rd 						: out STD_LOGIC;
      cs 							: out STD_LOGIC;
      Dout 						: out STD_LOGIC_VECTOR (7 downto 0));
	END COMPONENT;	
	
	COMPONENT icon
	PORT (
    CONTROL0 : INOUT STD_LOGIC_VECTOR(35 DOWNTO 0));
	END COMPONENT;
	
	COMPONENT ila
	PORT (
    CONTROL 							: INOUT STD_LOGIC_VECTOR(35 DOWNTO 0);
    CLK 									: IN STD_LOGIC;
    DATA 								: IN STD_LOGIC_VECTOR(99 DOWNTO 0);
    TRIG0 								: IN STD_LOGIC_VECTOR(0 TO 0));
	END COMPONENT;

BEGIN
--PORT MAPS:
	myCPU_gen 							: CPU_gen			Port Map (clk,'0',CPU_RDY,CPU_ADD,CPU_W_R,CPU_CS,CPU_Dout);
	SDRAM 								: SDRAMController	Port Map (clk,SDRAM_ADD,SDRAM_W_R,SDRAM_MSTRB,SDRAM_Din,SDRAM_Dout);
	mySRAM 								: SRAM				Port Map (clk,sWen,sADD, sDin, sDout);
	myIcon 								: icon 				Port Map (CONTROL0);
	myILA 								: ila					Port Map (CONTROL0,CLK,ila_data, TRIG0);
	
process(clk, CPU_CS)											-- Synchronous FSM; CPU_CS is only used for conditional check
	begin
		if (clk'event AND clk = '1') then  				-- rising edge
			--Setting the signal values
			if (state_current = state4) then 			-- READY: sample CPU request and decide hit/miss
				CPU_RDY 	<= '0';								-- busy while processing current request
				cpu_tag 		<= CPU_ADD(15 downto 8);	-- extract CPU tag (upper 8 bits of 16-bit addr)
				index		<= CPU_ADD(7  downto 5);		-- index (3 bit)
				offset	<= CPU_ADD(4  downto 0);			-- offset (5 bits, 32-byte block)
				SDRAM_ADD(15 downto 5) 	<= CPU_ADD(15 downto 5);	-- pre-load SDRAM address high bits with CPU tag+index
				sADD(7 downto 0) 			<= CPU_ADD(7 downto 0);		-- SRAM address = index[7:5] & offset[4:0]
				sWen <= "0"; 									-- default: no SRAM write in READY

				--Evaluating a HIT/MISS
				if(Vbit(to_integer(unsigned(index))) = '1' 
					AND memtag(to_integer(unsigned(index))) = cpu_tag) then -- HIT: valid and matching tag
					TAGWen <= '1';								-- (debug/visibility) indicate tag is valid/atched
					state_current 	<= state0;				-- go serve the access in HIT state
					state 		<= "0000";					-- expose state code for ILA
				else --MISS
					TAGWen <= '0';
					--Dirty and Valid bit check (choose WB first if vistim is valid+dirty)
					if (Dbit(to_integer(unsigned(index))) = '1' 
						AND Vbit(to_integer(unsigned(index))) = '1') then
						--Need to write back to main memory (SDRAM) before loading to cache memory (SRAM)
						state_current 	<= state2; --Switching to write back state
						state 		<= "0010";
						victim_tag <= memtag(to_integer(unsigned(index))); -- latch victim tag
						victim_index <= index;										-- latch victim index
					else --no write back needed as valid or dirty bit is 0
						state_current	<= state1;			-- go to LOAD
						state			<= "0001";
					end if;
				end if;
			
			elsif(state_current = state0) then -- HIT: serve CPU from cache(read) or write into cache (write)
		--update signals
				if (CPU_W_R = '1') then 		  -- WRITE-HIT
					sWen <= "1";					  -- enable SRAM write
					Dbit(to_integer(unsigned(index))) <= '1';	 -- mark line dirty
					Vbit(to_integer(unsigned(index))) <= '1';	 -- ensure valid bit set
					sDin <= CPU_Dout;									 -- data from CPU goes into SRAM
					CPU_Din <= "00000000";							 -- CPU not reading in write-hit
					
				else 							-- READ-HIT
					CPU_Din <= sDout;		-- return data from SRAM to CPU
				end if;		
				
				state_current <= state3; --request done -> go IDLE
				state <= "0011";
				
			elsif(state_current = state1) then  -- LOAD: read a full block from SFDRAM -> SRAM (clean miss or after WB)
		--loading from main memory
			if (counter = 64) then              -- reset cycle cpunter
					counter <= 0;
					Vbit(to_integer(unsigned(index))) <= '1'; -- mark vbit = 1
					memtag(to_integer(unsigned(index))) <= cpu_tag; -- store new tag
					sdoffset <= 0;										-- reset block offset
					state_current <= state0;						-- return to HIT to finish original op
					state <= "0000";
				else														-- still transferring block
					if (counter mod 2 = 1) then					-- odd cycles: keep srobe low (idle cycle)
						SDRAM_MSTRB <= '0';							
					else													-- even cycles: issue one byte transfer
						SDRAM_ADD(4 downto 0) <= STD_LOGIC_VECTOR(to_unsigned(sdoffset, 5)); -- SDRAM byte offset
						SDRAM_W_R <= '0';								-- READ from SDRAM
						SDRAM_MSTRB <= '1';							-- pulse strboe to transfer one byte
						sADD(7 downto 5) <= index;					-- SRAM address (index)
						sADD(4 downto 0) <= STD_LOGIC_VECTOR(to_unsigned(sdoffset, 5));		  -- SRAM byte offset
						sDin <= SDRAM_Dout;							-- data from SDRAM into SRAM
						sWen <= "1";									-- write to SRAM
						sdoffset <= sdoffset + 1;						-- next byte within the 32-byte block
					end if;
					counter <= counter + 1;							-- advance cycle counter
				end if;		
				
			elsif(state_current = state2) then 					-- WRITE-BACK: write victim block SRAM -> SDRAM (dirty miss)
				--writing back to main memory as valid or dirty bit is 1
			if (counter = 64) then									-- finished 32 bytes (64 cycles)
					counter <= 0;										-- reset
					Dbit(to_integer(unsigned(victim_index))) <= '0';	-- clear dirty on victim line
					sdoffset <= 0;										-- reset offset
					state_current <= state1;						-- now load the requested block
					state <= "0001";
				else														-- still transferring victim block
					if (counter mod 2 = 1) then					-- odd cycles: strobe low
						SDRAM_MSTRB <= '0';							
					else													-- even cycles: issue write of one byte
						SDRAM_ADD (15 downto 8) <= victim_tag; -- victim tag back to SDRAM
						SDRAM_ADD (7 downto 5) <= victim_index; -- victim index
						SDRAM_ADD(4 downto 0) <= STD_LOGIC_VECTOR(to_unsigned(sdoffset, 5)); -- byte offset
						SDRAM_W_R <= '1';																	  -- WRITE to SDRAM
						sADD(7 downto 5) <= victim_index;											  -- read from SDRAM at victim line
						sADD(4 downto 0) <= STD_LOGIC_VECTOR(to_unsigned(sdoffset, 5));      
						sWen <= "0";									-- SRAM is being read, not written
						SDRAM_Din <= sDout;							-- drive SDRAM data with SRAM output
						SDRAM_MSTRB <= '1';							-- pulse strobe to write one byte
						sdoffset <= sdoffset + 1;						-- next byte
					end if;
					counter <= counter + 1;							-- advance cycle counter
				end if;
				
			elsif(state_current = state3) then					-- IDLE: signal ready and wait for next CPU_CS
				CPU_RDY <= '1';										-- controller ready for next request
				if (CPU_CS = '1') then								-- CPU presents a new transaction
					state_current <= state4;						-- go to READY and re-evaluate
					state <= "0100";									
				end if;
			end if;
		end if;	
end process;
	
	MEMSTRB <= SDRAM_MSTRB;
	ADDR 	<= CPU_ADD;
	WR_RD <= CPU_W_R;
	DOUT	<= CPU_Din;
	RDY	<= CPU_RDY;
	CS 	<= CPU_CS;
	
	sAddra <= sADD;
	sDina <= sDin;
	sDouta <= sDout;
	
	sD_Addra <= SDRAM_ADD;
	sD_Dina <= SDRAM_Din;
	sD_Douta <= SDRAM_Dout;
	
	cacheAddr <= CPU_ADD(15 downto 8);
	
-- MAP THE ILA PORTS
	ila_data(15 downto 0) <= CPU_ADD;
	ila_data(16) <= CPU_W_R;
	ila_data(17) <= CPU_RDY;
	ila_data(18) <= SDRAM_MSTRB;
	ila_data(26 downto 19) <= CPU_Din;
	ila_data(30 downto 27) <= state;
	ila_data(31) <= CPU_CS;
	ila_data(32) <= Vbit(to_integer(unsigned(index)));
	ila_data(33) <= Dbit(to_integer(unsigned(index)));
	ila_data(34) <= TAGWen;
	ila_data(42 downto 35) <= sADD;
	ila_data(50 downto 43) <= sDin;
	ila_data(58 downto 51) <= sDout;
	ila_data(74 downto 59) <= SDRAM_ADD;
	ila_data(82 downto 75) <= SDRAM_Din;
	ila_data(90 downto 83) <= SDRAM_Dout;
	ila_data(98 downto 91) <= CPU_ADD(15 downto 8);

end Behavioral;