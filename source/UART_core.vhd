--------------------------------------------------------------------------------
-- UART CORE    
-- Implements a universal asynchronous receiver transmitter with parameterisable
-- BAUD rate. This was tested on a Spartan 6 LX9 connected to a Silicon Labs
-- CP2102 USB-UART Bridge.
--           
-- @author         Peter A Bennett
-- @copyright      (c) 2012 Peter A Bennett
-- @version        $Rev: 2 $
-- @lastrevision   $Date: 2012-03-11 15:19:25 +0000 (Sun, 11 Mar 2012) $
-- @license        LGPL      
-- @email          pab850@googlemail.com
-- @contact        www.bytebash.com
--
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity UART_core is
    Generic (
            BAUD_RATE           : positive;
            CLOCK_FREQUENCY     : positive
        );
    Port (  -- General
            CLOCK100M           :   in      std_logic;
            RESET               :   in      std_logic;    
            DATA_STREAM_IN      :   in      std_logic_vector(7 downto 0);
            DATA_STREAM_IN_STB  :   in      std_logic;
            DATA_STREAM_IN_ACK  :   out     std_logic := '0';
            DATA_STREAM_OUT     :   out     std_logic_vector(7 downto 0);
            DATA_STREAM_OUT_STB :   out     std_logic;
            DATA_STREAM_OUT_ACK :   in      std_logic;
            TX                  :   out     std_logic;
            RX                  :   in      std_logic
         );
end UART_core;

architecture RTL of UART_core is
    -- Functions
    function log2(A: integer) return integer is
    begin
      for I in 1 to 30 loop  -- Works for up to 32 bit integers
        if(2**I > A) then return(I-1);  end if;
      end loop;
      return(30);
    end;
    
    -- Baud Rate Generation
    constant c_tx_divider_val : integer := CLOCK_FREQUENCY / BAUD_RATE;
    constant c_rx_divider_val : integer := CLOCK_FREQUENCY / (BAUD_RATE * 16);
    constant tx_divider     :   unsigned (log2(c_tx_divider_val) downto 0) := to_unsigned(c_tx_divider_val,log2(c_tx_divider_val) + 1);
    constant rx_divider     :   unsigned (log2(c_rx_divider_val) downto 0) := to_unsigned(c_rx_divider_val,log2(c_rx_divider_val) + 1);
    signal baud_counter             :   unsigned (tx_divider'length - 1 downto 0) := (others => '0');   
    signal baud_tick                :   std_logic := '0';
    signal oversample_baud_counter  :   unsigned (rx_divider'length - 1 downto 0) := (others => '0');   
    signal oversample_baud_tick     :   std_logic := '0';
    -- Transmitter Signals
    type    uart_tx_states is (idle, wait_for_tick, send_start_bit, transmit_data, send_stop_bit);
    signal  uart_tx_state       : uart_tx_states := idle;
    signal  uart_tx_data_block  : std_logic_vector(7 downto 0) := (others => '0');
    signal  uart_tx_data        : std_logic := '1';
    signal  uart_tx_count       : integer   := 0;
    signal  uart_rx_data_in_ack : std_logic := '0';
    -- Receiver Signals
    type    uart_rx_states is (rx_wait_start_synchronise, rx_get_start_bit, rx_get_data, rx_get_stop_bit, rx_send_block);
    signal  uart_rx_state       : uart_rx_states := rx_get_start_bit;
    signal  uart_rx_bit         : std_logic := '0';
    signal  uart_rx_data_block  : std_logic_vector(7 downto 0) := (others => '0');
    signal  uart_rx_data_vec    : std_logic_vector(1 downto 0) := (others => '0');
    signal  uart_rx_filter      : unsigned(1 downto 0)  := (others => '0');
    signal  uart_rx_count       : integer   := 0;
    signal  uart_rx_data_out_stb: std_logic := '0';
    signal  uart_rx_bit_spacing : unsigned (3 downto 0) := (others => '0');
    signal  uart_rx_bit_tick    : std_logic := '0';
begin

    DATA_STREAM_IN_ACK  <= uart_rx_data_in_ack;
    DATA_STREAM_OUT     <= uart_rx_data_block;
    DATA_STREAM_OUT_STB <= uart_rx_data_out_stb;
    TX                  <= uart_tx_data;

    -- The input clock is 100Mhz, this needs to be divided down to the
    -- rate dictated by the BAUD_RATE. For example, if 115200 baud is selected
    -- (115200 baud = 115200 bps - 115.2kbps) a tick must be generated once every 1/115200
    TX_CLOCK_DIVIDER   : process (CLOCK100M)
    begin
        if rising_edge (CLOCK100M) then
            if RESET = '1' then
                baud_counter     <= (others => '0');
                baud_tick        <= '0';    
            else
                if baud_counter = tx_divider then
                    baud_counter <= (others => '0');
                    baud_tick    <= '1';
                else
                    baud_counter <= baud_counter + 1;
                    baud_tick    <= '0';
                end if;
            end if;
        end if;
    end process TX_CLOCK_DIVIDER;
            
    -- Get data from DATA_STREAM_IN and send it one bit at a time
    -- upon each BAUD tick. LSB first.
    -- Wait 1 tick, Send Start Bit (0), Send Data 0-7, Send Stop Bit (1)
    UART_SEND_DATA :    process(CLOCK100M)
    begin
        if rising_edge(CLOCK100M) then
            if RESET = '1' then
                uart_tx_data            <= '1';
                uart_tx_data_block      <= (others => '0');
                uart_tx_count           <= 0;
                uart_tx_state           <= idle;
                uart_rx_data_in_ack     <= '0';
            else
                uart_rx_data_in_ack     <= '0';
                case uart_tx_state is
                    when idle =>
                        if DATA_STREAM_IN_STB = '1' then
                            uart_tx_data_block  <= DATA_STREAM_IN;
                            uart_rx_data_in_ack <= '1';
                            uart_tx_state       <= wait_for_tick;
                        end if;                                   
                    when wait_for_tick =>
                        if baud_tick = '1' then
                            uart_tx_state   <= send_start_bit;
                        end if;
                    when send_start_bit =>
                        if baud_tick = '1' then
                            uart_tx_data    <= '0';
                            uart_tx_state   <= transmit_data;
                            uart_tx_count   <= 0;
                        end if;
                    when transmit_data =>
                        if baud_tick = '1' then
                            if uart_tx_count < 7 then
                                uart_tx_data    <= uart_tx_data_block(uart_tx_count);
                                uart_tx_count   <= uart_tx_count + 1;
                            else
                                uart_tx_data    <= uart_tx_data_block(7);
                                uart_tx_count   <= 0;
                                uart_tx_state   <= send_stop_bit;
                            end if;
                        end if;
                    when send_stop_bit =>
                        if baud_tick = '1' then
                            uart_tx_data <= '1';
                            uart_tx_state <= idle;
                        end if;
                    when others =>
                        uart_tx_data <= '1';
                        uart_tx_state <= idle;
                end case;
            end if;
        end if;
    end process UART_SEND_DATA;    
    
    -- Generate an oversampled tick (BAUD * 16)
    OVERSAMPLE_CLOCK_DIVIDER   : process (CLOCK100M)
    begin
        if rising_edge (CLOCK100M) then
            if RESET = '1' then
                oversample_baud_counter     <= (others => '0');
                oversample_baud_tick        <= '0';    
            else
                if oversample_baud_counter = rx_divider then
                    oversample_baud_counter <= (others => '0');
                    oversample_baud_tick    <= '1';
                else
                    oversample_baud_counter <= oversample_baud_counter + 1;
                    oversample_baud_tick    <= '0';
                end if;
            end if;
        end if;
    end process OVERSAMPLE_CLOCK_DIVIDER;
    -- Synchronise RXD to the oversampled BAUD
    RXD_SYNCHRONISE : process(CLOCK100M)
    begin
        if rising_edge(CLOCK100M) then
            if RESET = '1' then
                uart_rx_data_vec   <= (others => '1');
            else
                if oversample_baud_tick = '1' then
                    uart_rx_data_vec(0)    <= RX;
                    uart_rx_data_vec(1)    <= uart_rx_data_vec(0);
                end if;
            end if;
        end if;
    end process RXD_SYNCHRONISE;
    
    -- Filter RXD with a 2 bit counter.
    RXD_FILTER  :   process(CLOCK100M)
    begin
        if rising_edge(CLOCK100M) then
            if RESET = '1' then
                uart_rx_filter <= (others => '1');
                uart_rx_bit    <= '1';
            else
                if oversample_baud_tick = '1' then
                    -- Filter RXD.
                    if uart_rx_data_vec(1) = '1' and uart_rx_filter < 3 then
                        uart_rx_filter <= uart_rx_filter + 1;
                    elsif uart_rx_data_vec(1) = '0' and uart_rx_filter > 0 then
                        uart_rx_filter <= uart_rx_filter - 1;
                    end if;
                    -- Set the RX bit.
                    if uart_rx_filter = 3 then
                        uart_rx_bit <= '1';
                    elsif uart_rx_filter = 0 then
                        uart_rx_bit <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process RXD_FILTER;
    
    RX_BIT_SPACING : process (CLOCK100M)
    begin
        if rising_edge(CLOCK100M) then
            uart_rx_bit_tick <= '0';
            if oversample_baud_tick = '1' then       
                if uart_rx_bit_spacing = 15 then
                    uart_rx_bit_tick <= '1';
                    uart_rx_bit_spacing <= (others => '0');
                else
                    uart_rx_bit_spacing <= uart_rx_bit_spacing + 1;
                end if;
                if uart_rx_state = rx_get_start_bit then
                    uart_rx_bit_spacing <= (others => '0');
                end if; 
            end if;
        end if;
    end process RX_BIT_SPACING;
    
    UART_RECEIVE_DATA   : process(CLOCK100M)
    begin
        if rising_edge(CLOCK100M) then
            if RESET = '1' then
                uart_rx_state           <= rx_get_start_bit;
                uart_rx_data_block      <= (others => '0');
                uart_rx_count           <= 0;
                uart_rx_data_out_stb    <= '0';
            else
                case uart_rx_state is
                    when rx_get_start_bit =>
                        if oversample_baud_tick = '1' and uart_rx_bit = '0' then
                            uart_rx_state <= rx_get_data;
                        end if;
                    when rx_get_data =>
                        if uart_rx_bit_tick = '1' then
                            if uart_rx_count < 7 then
                                uart_rx_data_block(uart_rx_count) <= uart_rx_bit;
                                uart_rx_count   <= uart_rx_count + 1;
                            else
                                uart_rx_data_block(7) <= uart_rx_bit;
                                uart_rx_count <= 0;
                                uart_rx_state <= rx_get_stop_bit;
                            end if;
                        end if;
                    when rx_get_stop_bit =>
                        if uart_rx_bit_tick = '1' then
                            if uart_rx_bit = '1' then
                                uart_rx_state <= rx_send_block;
                                uart_rx_data_out_stb    <= '1';
                            end if;
                        end if;
                    when rx_send_block =>
                        if DATA_STREAM_OUT_ACK = '1' then
                            uart_rx_data_out_stb    <= '0';
                            uart_rx_data_block      <= (others => '0');
                            uart_rx_state           <= rx_get_start_bit;
                        else
                            uart_rx_data_out_stb    <= '1';
                        end if;                                
                    when others =>
                        uart_rx_state   <= rx_get_start_bit;
                end case;
            end if;
        end if;
    end process UART_RECEIVE_DATA;
end RTL;
