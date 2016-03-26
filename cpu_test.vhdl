library ieee;
USE ieee.std_logic_1164.ALL;
use ieee.numeric_std.all;
use work.all;
use work.debugtools.all;

entity cpu_test is
  
end cpu_test;

architecture behavior of cpu_test is

  signal pixelclock : std_logic := '0';
  signal cpuclock : std_logic := '0';
  signal ioclock : std_logic := '0';
  signal reset : std_logic := '0';
  signal irq : std_logic := '1';
  signal nmi : std_logic := '1';

  signal monitor_pc : unsigned(15 downto 0);
  
  
begin

  -- instantiate components here
  core0: entity work.gs4502b
    port map (
      cpuclock => cpuclock,
      reset => reset,
      monitor_pc => monitor_pc,      
      rom_at_8000 => '0',
      rom_at_a000 => '0',
      rom_at_c000 => '0',
      rom_at_e000 => '0',
      viciii_iomode => "11"
      );
  
  process
  begin  -- process tb
    report "beginning simulation" severity note;

    -- Assert reset for 16 cycles to give CPU pipeline ample time to flush out
    -- and actually reset.
    reset <= '0';
    for i in 1 to 4 loop
      pixelclock <= '1'; cpuclock <= '1'; ioclock <= '1'; wait for 2.5 ns;     
      pixelclock <= '0'; cpuclock <= '0'; ioclock <= '1'; wait for 2.5 ns;     
      pixelclock <= '1'; cpuclock <= '1'; ioclock <= '1'; wait for 2.5 ns;     
      pixelclock <= '0'; cpuclock <= '0'; ioclock <= '1'; wait for 2.5 ns;     
      pixelclock <= '1'; cpuclock <= '1'; ioclock <= '0'; wait for 2.5 ns;     
      pixelclock <= '0'; cpuclock <= '0'; ioclock <= '0'; wait for 2.5 ns;     
      pixelclock <= '1'; cpuclock <= '1'; ioclock <= '0'; wait for 2.5 ns;     
      pixelclock <= '0'; cpuclock <= '0'; ioclock <= '0'; wait for 2.5 ns;     
    end loop;  -- i
    -- Run CPU for 8 million cycles.
    reset <= '1';
    for i in 1 to 2000000 loop
      pixelclock <= '1'; cpuclock <= '1'; ioclock <= '1'; wait for 2.5 ns;     
      pixelclock <= '0'; cpuclock <= '0'; ioclock <= '1'; wait for 2.5 ns;     
      pixelclock <= '1'; cpuclock <= '1'; ioclock <= '1'; wait for 2.5 ns;     
      pixelclock <= '0'; cpuclock <= '0'; ioclock <= '1'; wait for 2.5 ns;     
      pixelclock <= '1'; cpuclock <= '1'; ioclock <= '0'; wait for 2.5 ns;     
      pixelclock <= '0'; cpuclock <= '0'; ioclock <= '0'; wait for 2.5 ns;     
      pixelclock <= '1'; cpuclock <= '1'; ioclock <= '0'; wait for 2.5 ns;     
      pixelclock <= '0'; cpuclock <= '0'; ioclock <= '0'; wait for 2.5 ns;     
    end loop;  -- i
    assert false report "End of simulation" severity failure;
  end process;

  
end behavior;

