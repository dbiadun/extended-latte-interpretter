# Extended Latte Interpreter

This program is an interpreter of extended Latte programming language described in description.md.

## Files

 - Parser/* - files generated by bnfc with little changes (used to parse the code)
 - StaticCheck.hs - static check module
 - Interpreter.hs - interpreter module (used to interpret program after static check)
 - Main.hs - main file of the project (loads and runs other modules)
 - good/* - examples of correct programs
 - bad/* - examples of incorrect programs
 - grammar.cf - grammar for bnfc
 - description.md - language description

## Compilation and running

To compile interpreter simply use `make`.

To run any program in our language - `./interpreter program`.