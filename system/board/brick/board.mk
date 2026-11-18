# The TrimUI Brick: the only board of the brick family (Allwinner A133P, TrimUI's 4.9 kernel).
# Board: one device model. Family: boards that share one kernel and one root filesystem
# (system/family/<family>). SoC: a mainline board's main chip (system/soc/<soc>: its kernel options).
# tools/ reads this file with grep and sed: keep the exact "NAME := value" form, one per line.
FAMILY := brick
