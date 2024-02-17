# Output files

Here, using the results produced in the [Non-bacterial dataset section](non_bacteria.md#), we give users a glimpse over the main outputs produced by MpGAP. The command used in there wrote the results under the `genome_assembly` directory.

!!! note

    Please take note that the pipeline uses the directory set with the `--output` parameter as a storage place in which it will create a folder for the final results, separated by sample, technology and assembly strategy.

## Directory tree

After a successful execution, you will have something like this:

```bash
# Directory tree from the running dir
genome_assembly
├── aspergillus_fumigatus           # directory containing the assembly results for a given sample these are written with the 'id' value. In our example we have only one, but if input data samplesheet had more samples we would have one sub-directory for each.
│   └── longreads_only              # results for long reads only assembly. A sub-directory is created for results of each assembly strategy to allow you running multiple strategies at once
│       ├── 00_quality_assessment   # QC reports
│       ├── canu                    # Canu assembly
│       ├── flye                    # Flye assembly
│       ├── medaka_polished_contigs # Assemblies of all assemblers polished with medaka
│       ├── raven                   # Raven assembly
│       ├── shasta                  # Shasta assembly
│       └── wtdbg2                  # Shasta assembly
├── final_assemblies                # A folder contatining a copy of all the assemblies generated, raw and polished
│   ├── aspergillus_fumigatus_canu_assembly.fasta
│   ├── aspergillus_fumigatus_canu_medaka_consensus.fa
│   ├── aspergillus_fumigatus_flye_assembly.fasta
│   ├── aspergillus_fumigatus_flye_medaka_consensus.fa
│   ├── < ... > etc.
├── input.yml                       # Copy of given input samplesheet for data provenance
└── pipeline_info                   # directory containing the nextflow execution reports
    ├── mpgap_report_2023-12-28_12-25-18.html
    ├── mpgap_timeline_2023-12-28_12-25-18.html
    └── mpgap_tracing_2023-12-28_12-25-18.txt
```

## Example of QC outputs

Here I am going to display just a very few examples of results produced, focusing on the QC, as the main result is a normal assembly, performed by each assembler.

**Summary of Assembly Statistics in TXT format**

Open it [here](../assets/ASSEMBLY_SUMMARY.txt).

**MultiQC Report - HTML**

Open it [here](../assets/multiqc_report_nasty_lorenz.html).

**Quast Report of Flye assembly - HTML**

Open it [here](../assets/flye_medaka/report.html).