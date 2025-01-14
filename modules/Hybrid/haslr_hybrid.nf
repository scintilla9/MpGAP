process haslr_hybrid {
  publishDir "${params.output}/${prefix}", mode: 'copy'
  tag "${id}"
  label 'process_assembly'

  input:
  tuple val(id), val(entrypoint), file(sread1), file(sread2), file(single), file(lreads), val(lr_type), val(wtdbg2_technology), val(genome_size), val(corrected_long_reads), val(medaka_model), file(fast5), val(nanopolish_max_haplotypes), val(shasta_config), file(bams), val(prefix)

  output:
  file "*" // Save everything
  tuple val(id), file("haslr/haslr_assembly.fa"), val('haslr') // Gets contigs file

  when:
  ((!(sread1 =~ /input.*/) && !(sread2 =~ /input.*/)) || !(single =~ /input.*/)) && !(lreads =~ /input.*/) && (entrypoint == 'hybrid_strategy_1')

  script:
  // Check reads
  paired_reads = (!(sread1 =~ /input.*/) && !(sread2 =~ /input.*/)) ? "$sread1 $sread2" : ""
  single_reads = !(single =~ /input.*/) ? "$single" : ""
  additional_params = (params.haslr_additional_parameters) ? params.haslr_additional_parameters : ""
  """
  # run haslr
  haslr.py \\
      -t $task.cpus \\
      -o haslr \\
      -g ${genome_size} \\
      -l $lreads \\
      -x ${lr_type} \\
      $additional_params \\
      -s ${paired_reads} ${single_reads} 

  # rename results
  cp haslr/*/asm.final.fa haslr/haslr_assembly.fa
  """
}
