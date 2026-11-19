Tony359's VRAM TEST for GD542x v0.2
===================================
Video memory tester for Cirrus Logic CL-GD542x cards (1 MB).

RUNNING IT
  1. Boot DOS clean (no EMM386). Needs a 386 or later CPU.
  2. Copy VRAMTEST.COM to the CF card and run:  VRAMTEST
  3. The intro screen waits: Enter = start, Esc = quit.
  4. Each pass:
       - 29 tests over all 1 MB in 256-colour mode (32-bit reads)
       - a planar split test in 16-colour mode (byte reads)
     The screen shows test patterns while it runs. That is normal.
  5. After each pass the report shows for 10 s, then the next pass starts.
       Enter = start now   D = details page   Space = pause   Esc = quit
     Esc also stops a pass in progress (within about a second).
  6. Results are added to VRAMTEST.LOG in the current directory after
     every pass, so they survive a garbled screen or a crash.

  VRAMTEST /F  runs even if the chip ID is not a CL-GD542x.
  Only use it on Cirrus GD542x cards with 1 MB. On other chips the memory
  banking does not work and the results are meaningless.

MAIN REPORT (all counts are totals since the program started)
  Bit errors per data line
      One count per wrong bit, for each memory data line MD0-MD31 of the
      graphics chip (pins 97-136). Lane 0 = MD0-7 ... Lane 3 = MD24-31.
      ->0  the bit always read 0 when 1 was written
      ->1  the bit always read 1 when 0 was written
      mix  both directions happened (the line is not simply stuck)

  Fixed patterns / Addr/random/scroll / Planar split
      Errors in each group of tests.
      Fixed patterns fail too: a data problem.
      Only address/random/scroll fail: an addressing problem.

  Types
      read glitch  wrong on the first read, right on the second read
      repeatable   wrong twice, the same way
      unstable     wrong twice, differently

  Errors per 64 KB block
      Where in the 1 MB the errors are (block 0 = first 64 KB).

  Address test, wrong address bits
      Repeatable errors in the Address test where the value read is the
      address of another location. Data-line errors can also show up here,
      so only trust it when the fixed patterns are clean.

  First errors this pass
      Test name, address, value written, value read, value re-read.

DETAILS PAGE (press D during the 10 s wait)
  Errors per test
      Totals for each of the 29 tests, plus the planar split test.

  Planar split test
      Writes and reads one byte at a time, one memory plane at a time, at
      even and odd CPU addresses (first 64 KB of each plane).
      Even addresses travel on the card's host data bus D0-7, odd addresses
      on D8-15, whatever the plane. Each plane is one byte lane of video
      memory: plane 0 = MD0-7 ... plane 3 = MD24-31.

                          even address   odd address
        Plane 0 (MD0-7)        a              b
        Plane 1 (MD8-15)       c              d
        Plane 2 (MD16-23)      e              f
        Plane 3 (MD24-31)      g              h

      Errors in the odd column for every plane: host data bus D8-15
        (graphics chip host data pins, the 245 buffers carrying odd bytes).
      Errors in both columns but only for some planes: video memory on
        those planes (data lines, DRAM chips).

THE TESTS (each fills all 1 MB, then reads it back)
  Address, Addr inv   every dword holds its own address (and inverted)
  Scroll              copies each 64 KB block 256 bytes down, like a
                      text scroll (read + write), then checks it
  All 0s, All 1s, Check 55/AA/33/CC/0F/F0
  Walk1 b0-b7         one bit set in every byte
  Walk0 b0-b7         one bit clear in every byte
  Random              random data
  Hold 3s             random data, waits 3 seconds, then checks it
  Planar split        5 byte patterns per plane (55, AA, address mix,
                      inverted address mix, random)

ASSUMPTION
  In 256-colour mode 5Fh the program assumes byte address L is stored in
  byte lane (L AND 3). If the line it reports beeps to a chip that tests
  fine, the lane mapping may differ on this card.
