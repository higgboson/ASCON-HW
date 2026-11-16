# imc_merge.tcl - merge every coverage run of one scope (SCOPE = rpc1, rpc2 or rpc4)
# into cov_work/scope/merged (IMC puts a relative -out under cov_work/scope/)
set scope $::env(SCOPE)
merge cov_work/$scope/* -out merged -overwrite -initial_model union_all
exit
