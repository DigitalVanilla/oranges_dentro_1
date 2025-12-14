VASM = vasmm68k_mot

main.exe: main.asm
# 	$(VASM) -Fhunkexe -linedebug -kick1hunks -o $@ $<
	$(VASM) -Fhunkexe -nosym -kick1hunks -o $@ $<