# The Powkiddy RGB20 Pro (Rockchip RK3566). DTB: its device tree in our kernel (linux-mainline).
# Board: one device model. Family: boards that share one kernel and one root filesystem
# (system/family/<family>). SoC: a mainline board's main chip (system/soc/<soc>: its kernel options).
# tools/ reads this file with grep and sed: keep the exact "NAME := value" form, one per line.
FAMILY := mainline
SOC := rk3566
DTB := rockchip/rk3566-powkiddy-rgb20-pro.dtb
