# imc_report.tcl - summary and detailed reports of the merged coverage of one scope
set scope $::env(SCOPE)
load -run cov_work/scope/merged
# exclusions saved from the IMC GUI (docs/coverage/README.md, step 6)
if {[file exists ascon_exclusions.vRefine]} {
    puts "loading exclusions from ascon_exclusions.vRefine"
    load -refinement ascon_exclusions.vRefine
}
report -summary -inst -metrics all -out reports/${scope}_summary.txt
report -detail -metrics covergroup -out reports/${scope}_functional_detail.txt
report -detail -metrics assertion -out reports/${scope}_assertions.txt
exit
