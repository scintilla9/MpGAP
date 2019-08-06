#!/usr/bin/env nextflow

// Loading general parameters
prefix = params.prefix
outdir = params.outDir
threads = params.threads
genomeSize = params.canu.genomeSize
assembly_type = params.assembly_type
// Reference genome
ref_genome = (params.ref_genome) ? file(params.ref_genome) : ''

/*
 * PARSING YAML FILE
 */

import org.yaml.snakeyaml.Yaml
//Def method for addtional parameters
class MyClass {
def getAdditional(String file, String value) {
  def yaml = new Yaml().load(new FileReader("$file"))
  def output = ""
  if ( "$value" == "canu" ) {
    yaml."$value".each {
  	   def (k, v) = "${it}".split( '=' )
  	    if ((v ==~ /null/ ) || (v == "")) {} else {
  	       output = output + " " + "${it}"
  	}}
    return output
  } else {
  yaml."$value".each {
    def (k, v) = "${it}".split( '=' )
    if ( v ==~ /true/ ) {
      output = output + " --" + k
      } else if ( v ==~ /false/ ) {}
        else if ((v ==~ /null/ ) || (v == "")) {} else {
          if ( k ==~ /k/ ) { output = output + " -" + k + " " + v }
          else { output = output + " --" + k + " " + v }
    }}
    return output
  }}}

if ( params.yaml ) {} else {
  exit 1, "YAML file not found: ${params.yaml}"
}

//Creating map for additional parameters
def additionalParameters = [:]
additionalParameters['Spades'] = new MyClass().getAdditional(params.yaml, 'spades')
additionalParameters['Unicycler'] = new MyClass().getAdditional(params.yaml, 'unicycler')
additionalParameters['Canu'] = new MyClass().getAdditional(params.yaml, 'canu')
additionalParameters['Pilon'] = new MyClass().getAdditional(params.yaml, 'pilon')
additionalParameters['Flye'] = new MyClass().getAdditional(params.yaml, 'flye')

/*
 * PIPELINE BEGIN
 * Assembly with longreads-only
 * Canu and Nanpolish or Unicycler
 */

// Loading long reads files
canu_lreads = (params.longreads && (params.try.canu) && params.assembly_type == 'longreads-only') ?
              file(params.longreads) : Channel.empty()
unicycler_lreads = (params.longreads && (params.try.unicycler) && params.assembly_type == 'longreads-only') ?
                   file(params.longreads) : Channel.empty()
flye_lreads = (params.longreads && (params.try.flye) && params.assembly_type == 'longreads-only') ?
                   file(params.longreads) : Channel.empty()
if (params.fast5Path && params.assembly_type == 'longreads-only') {
  fast5 = Channel.fromPath( params.fast5Path )
  nanopolish_lreads = file(params.longreads)
  fast5_dir = Channel.fromPath( params.fast5Path, type: 'dir' )
} else { Channel.empty().into{fast5; fast5_dir; nanopolish_lreads} }

// CANU ASSEMBLER - longreads
process canu_assembly {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  cpus threads

  input:
  file lreads from canu_lreads

  output:
  file "*"
  file("canu_lreadsOnly_results_${lrID}/*.contigs.fasta") into canu_contigs

  when:
  (params.try.canu) && assembly_type == 'longreads-only'

  script:
  lr = (params.lr_type == 'nanopore') ? '-nanopore-raw' : '-pacbio-raw'
  lrID = lreads.getSimpleName()
  """
  canu -p ${prefix} -d canu_lreadsOnly_results_${lrID} maxThreads=${params.threads}\
  genomeSize=${genomeSize} ${additionalParameters['Canu']} $lr $lreads
  """
}

// UNICYCLER ASSEMBLER - longreads-only
process unicycler_longReads {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  cpus threads

  input:
  file lreads from unicycler_lreads

  output:
  file "unicycler_lreadsOnly_results_${lrID}/"
  file("unicycler_lreadsOnly_results_${lrID}/assembly.fasta") into unicycler_longreads_contigs

  when:
  (params.try.unicycler) && assembly_type == 'longreads-only'

  script:
  lrID = lreads.getSimpleName()
  """
  unicycler -l $lreads \
  -o unicycler_lreadsOnly_results_${lrID} -t ${params.threads} \
  ${additionalParameters['Unicycler']} &> unicycler.log
  """
}

// Flye ASSEMBLER - longreads
process flye_assembly {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  cpus threads

  input:
  file lreads from flye_lreads

  output:
  file "flye_lreadsOnly_results_${lrID}/"
  file("flye_lreadsOnly_results_${lrID}/scaffolds.fasta") optional true
  file("flye_lreadsOnly_results_${lrID}/assembly_flye.fasta") into flye_contigs

  when:
  (params.try.flye) && assembly_type == 'longreads-only'

  script:
  lr = (params.lr_type == 'nanopore') ? '--nano-raw' : '--pacbio-raw'
  lrID = lreads.getSimpleName()
  """
  source activate flye ;
  flye ${lr} $lreads --genome-size ${genomeSize} --out-dir flye_lreadsOnly_results_${lrID} \
  --threads $threads ${additionalParameters['Flye']} &> flye.log ;
  mv flye_lreadsOnly_results_${lrID}/assembly.fasta flye_lreadsOnly_results_${lrID}/assembly_flye.fasta
  """
}


// Creating channels for assesing longreads assemblies
// For Nanopolish, quast and variantCaller
if (params.fast5Path) {
    longread_assembly_nanopolish = Channel.empty().mix(flye_contigs, canu_contigs, unicycler_longreads_contigs)
    longread_assemblies_variantCaller = Channel.empty()
} else if (params.lr_type == 'pacbio' && params.pacbio.all.baxh5.path != '') {
  longread_assembly_nanopolish = Channel.empty()
  longread_assemblies_variantCaller = Channel.empty().mix(flye_contigs, canu_contigs, unicycler_longreads_contigs)
} else {
  longread_assembly_nanopolish = Channel.empty()
  longread_assemblies_variantCaller = Channel.empty()
}

/*
 * NANOPOLISH - A tool to polish nanopore only assemblies
 */
process nanopolish {
  publishDir "${outdir}/lreadsOnly_nanopolished_contigs", mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  cpus threads

  input:
  each file(draft) from longread_assembly_nanopolish
  file(reads) from nanopolish_lreads
  file fast5
  val fast5_dir from fast5_dir

  output:
  file("${prefix}_${assembler}_nanopolished.fa") into nanopolished_contigs

  when:
  assembly_type == 'longreads-only' && (params.fast5Path)

  script:
  if (draft.getName()  == 'assembly.fasta' || draft.getName() =~ /unicycler/) {
    assembler = 'unicycler'
    } else if (draft.getName()  == 'assembly_flye.fasta' || draft.getName() =~ /flye/) {
      assembler = 'flye'
      } else {
        assembler = 'canu'
        }
  """
  zcat -f ${reads} > reads ;
  if [ \$(grep -c "^@" reads) -gt 0 ] ; then sed -n '1~4s/^@/>/p;2~4p' reads > reads.fa ; else mv reads reads.fa ; fi ;
  nanopolish index -d "${fast5_dir}" reads.fa ;
  minimap2 -d draft.mmi ${draft} ;
  minimap2 -ax map-ont -t ${params.threads} ${draft} reads.fa | samtools sort -o reads.sorted.bam -T reads.tmp ;
  samtools index reads.sorted.bam ;
  python /miniconda/bin/nanopolish_makerange.py ${draft} | parallel --results nanopolish.results -P ${params.cpus} \
  nanopolish variants --consensus -o polished.{1}.fa \
    -w {1} \
    -r reads.fa \
    -b reads.sorted.bam \
    -g ${draft} \
    --min-candidate-frequency 0.1;
  python /miniconda/bin/nanopolish_merge.py polished.*.fa > ${prefix}_${assembler}_nanopolished.fa
  """
}

/*
 * VariantCaller - A pacbio only polishing step
 */

// Loading files
baxh5 = (params.pacbio.all.baxh5.path) ? Channel.fromPath(params.pacbio.all.baxh5.path).buffer( size: 3 ) : Channel.empty()

process bax2bam {
  publishDir "${outdir}/subreads", mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  cpus threads

  input:
  file(bax) from baxh5

  output:
  file "*.subreads.bam" into pacbio_bams

  when:
  params.lr_type == 'pacbio' && params.pacbio.all.baxh5.path != ''

  script:
  """
  source activate pacbio ;
  bax2bam ${bax.join(" ")} --subread  \
  --pulsefeatures=DeletionQV,DeletionTag,InsertionQV,IPD,MergeQV,SubstitutionQV,PulseWidth,SubstitutionTag;
  """
}

// Get bams together
variantCaller_bams = Channel.empty().mix(pacbio_bams).collect()

process variantCaller {
  publishDir "${outdir}/lreadsOnly_pacbio_consensus", mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  cpus threads

  input:
  each file(draft) from longread_assemblies_variantCaller
  file bams from variantCaller_bams

  output:
  file "${prefix}_${assembler}_pbvariants.gff"
  file "${prefix}_${assembler}_pbconsensus.fasta" into variant_caller_contigs

  when:
  params.lr_type == 'pacbio' && params.pacbio.all.baxh5.path != ''

  script:
  assembler = (draft.getName()  == 'assembly.fasta' || draft.getName() =~ /unicycler/) ? 'unicycler' : 'canu'
  """
  source activate pacbio;
  for BAM in ${bams.join(" ")} ; do pbalign --nproc ${params.threads}  \
  \$BAM ${draft} \${BAM%%.bam}_pbaligned.bam; done;
  for BAM in *_pbaligned.bam ; do samtools sort -@ ${params.threads} \
  -o \${BAM%%.bam}_sorted.bam \$BAM; done;
  samtools merge pacbio_merged.bam *_sorted.bam;
  samtools index pacbio_merged.bam;
  pbindex pacbio_merged.bam;
  samtools faidx ${draft};
  arrow -j ${params.threads} --referenceFilename ${draft} -o ${prefix}_${assembler}_pbconsensus.fasta \
  -o ${prefix}_${assembler}_pbvariants.gff pacbio_merged.bam
  """

}

/*
 * HYBRID ASSEMBLY WITH Unicycler and Spades
 */
// Spades
// Loading paired end short reads
short_reads_spades_hybrid_paired = (params.shortreads.paired && params.assembly_type == 'hybrid' \
                                    && (params.try.spades)) ?
                                    Channel.fromFilePairs( params.shortreads.paired, flat: true, size: 2 ) : Channel.value(['', '', ''])
// Loading single end short reads
short_reads_spades_hybrid_single = (params.shortreads.single && params.assembly_type == 'hybrid' \
                                    && (params.try.spades)) ?
                                    Channel.fromPath(params.shortreads.single) : ''
// Long reads
spades_hybrid_lreads = (params.longreads && params.assembly_type == 'hybrid' && (params.try.spades)) ?
                        file(params.longreads) : ''

// Assembly begin
process spades_hybrid_assembly {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  tag { x }
  cpus threads

  input:
  file lreads from spades_hybrid_lreads
  set val(id), file(sread1), file(sread2) from short_reads_spades_hybrid_paired
  file(sread) from short_reads_spades_hybrid_single
  file ref_genome from ref_genome

  output:
  file("spades_hybrid_results_${rid}/contigs.fasta") into spades_hybrid_contigs
  file "*"

  when:
  assembly_type == 'hybrid' && (params.try.spades)

  script:
  lr = (params.lr_type == 'nanopore') ? '--nanopore' : '--pacbio'
  spades_opt = (params.ref_genome) ? "--trusted-contigs $ref_genome" : ''

  if ((params.shortreads.single) && (params.shortreads.paired)) {
    parameter = "-1 $sread1 -2 $sread2 -s $sread $lr $lreads"
    rid = sread.getSimpleName() + "_and_" + sread1.getSimpleName()
    x = "Executing assembly with paired and single end reads"
  } else if ((params.shortreads.single) && (params.shortreads.paired == '')) {
    parameter = "-s $sread $lr $lreads"
    rid = sread.getSimpleName()
    x = "Executing assembly with single end reads"
  } else if ((params.shortreads.paired) && (params.shortreads.single == '')) {
    parameter = "-1 $sread1 -2 $sread2 $lr $lreads"
    rid = sread1.getSimpleName()
    x = "Executing assembly with paired end reads"
  }
  """
  spades.py -o "spades_hybrid_results_${rid}" -t ${params.threads} ${additionalParameters['Spades']} \\
  $parameter ${spades_opt}
  """
}

// Unicycler
// Loading paired end short reads
short_reads_unicycler_hybrid_paired = (params.shortreads.paired && params.assembly_type == 'hybrid' \
                                       && (params.try.unicycler)) ?
                                       Channel.fromFilePairs( params.shortreads.paired, flat: true, size: 2 ) : Channel.value(['', '', ''])
// Loading single end short reads
short_reads_unicycler_hybrid_single = (params.shortreads.single && params.assembly_type == 'hybrid' \
                                       && (params.try.unicycler)) ?
                                       Channel.fromPath(params.shortreads.single) : ''
// Long reads
unicycler_hybrid_lreads = (params.longreads && params.assembly_type == 'hybrid' && (params.try.unicycler)) ?
                          file(params.longreads) : ''

// Assembly begin
process unicycler_hybrid_assembly {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  tag { x }
  cpus threads

  input:
  set val(id), file(sread1), file(sread2) from short_reads_unicycler_hybrid_paired
  file(sread) from short_reads_unicycler_hybrid_single
  file lreads from unicycler_hybrid_lreads

  output:
  file "*"
  file("unicycler_hybrid_results_${rid}/assembly.fasta") into unicycler_hybrid_contigs

  when:
  assembly_type == 'hybrid' && (params.try.unicycler)

  script:
  if ((params.shortreads.single) && (params.shortreads.paired)) {
    parameter = "-1 $sread1 -2 $sread2 -s $sread -l $lreads"
    rid = sread.getSimpleName() + "_and_" + sread1.getSimpleName()
    x = "Executing assembly with paired and single end reads"
  } else if ((params.shortreads.single) && (params.shortreads.paired == '')) {
    parameter = "-s $sread -l $lreads"
    rid = sread.getSimpleName()
    x = "Executing assembly with single end reads"
  } else if ((params.shortreads.paired) && (params.shortreads.single == '')) {
    parameter = "-1 $sread1 -2 $sread2 -l $lreads"
    rid = sread1.getSimpleName()
    x = "Executing assembly with paired end reads"
  }
  """
  unicycler $parameter \\
  -o unicycler_hybrid_results_${rid} -t ${params.threads} \\
  ${additionalParameters['Unicycler']} &>unicycler.log
  """
}

/*
 * ILLUMINA-ONLY ASSEMBLY WITH Unicycler and Spades
 */
// Spades
// Loading short reads
short_reads_spades_illumina_paired = (params.shortreads.paired && params.assembly_type == 'illumina-only' \
                                      && (params.try.spades)) ?
                                      Channel.fromFilePairs( params.shortreads.paired, flat: true, size: 2 ) : Channel.value(['', '', ''])
// Loading short reads
short_reads_spades_illumina_single = (params.shortreads.single && params.assembly_type == 'illumina-only' \
                                      && (params.try.spades)) ?
                                      Channel.fromPath(params.shortreads.single) : ''
// Assembly begin
process spades_illumina_assembly {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  tag { x }
  cpus threads

  input:
  set val(id), file(sread1), file(sread2) from short_reads_spades_illumina_paired
  file(sread) from short_reads_spades_illumina_single
  file ref_genome from ref_genome

  output:
  file("spades_illuminaOnly_results_${rid}/contigs.fasta") into spades_illumina_contigs
  file "*"

  when:
  assembly_type == 'illumina-only' && (params.try.spades)

  script:
  spades_opt = (params.ref_genome) ? "--trusted-contigs $ref_genome" : ''
  if ((params.shortreads.single) && (params.shortreads.paired)) {
    parameter = "-1 $sread1 -2 $sread2 -s $sread"
    rid = sread.getSimpleName() + "_and_" + sread1.getSimpleName()
    x = "Executing assembly with paired and single end reads"
  } else if ((params.shortreads.single) && (params.shortreads.paired == '')) {
    parameter = "-s $sread"
    rid = sread.getSimpleName()
    x = "Executing assembly with single end reads"
  } else if ((params.shortreads.paired) && (params.shortreads.single == '')) {
    parameter = "-1 $sread1 -2 $sread2"
    rid = sread1.getSimpleName()
    x = "Executing assembly with paired end reads"
  }
  """
  spades.py -o "spades_illuminaOnly_results_${rid}" -t ${params.threads} ${additionalParameters['Spades']} \\
  $parameter ${spades_opt}
  """
}

// Unicycler
// Loading short reads
short_reads_unicycler_illumina_single = (params.shortreads.single && params.assembly_type == 'illumina-only' \
                                         && (params.try.unicycler)) ?
                                         Channel.fromPath(params.shortreads.single) : ''
short_reads_unicycler_illumina_paired = (params.shortreads.paired && params.assembly_type == 'illumina-only' \
                                         && (params.try.unicycler)) ?
                                         Channel.fromFilePairs( params.shortreads.paired, flat: true, size: 2 ) : Channel.value(['', '', ''])
// Assembly begin
process unicycler_illumina_assembly {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  tag { x }
  cpus threads

  input:
  file(sread) from short_reads_unicycler_illumina_single
  set val(id), file(sread1), file(sread2) from short_reads_unicycler_illumina_paired

  output:
  file "*"
  file("unicycler_illuminaOnly_results_${rid}/assembly.fasta") into unicycler_illumina_contigs

  when:
  assembly_type == 'illumina-only' && (params.try.unicycler)

  script:
  if ((params.shortreads.single) && (params.shortreads.paired)) {
    parameter = "-1 $sread1 -2 $sread2 -s $sread"
    rid = sread.getSimpleName() + "_and_" + sread1.getSimpleName()
    x = "Executing assembly with paired and single end reads"
  } else if ((params.shortreads.single) && (params.shortreads.paired == '')) {
    parameter = "-s $sread"
    rid = sread.getSimpleName()
    x = "Executing assembly with single end reads"
  } else if ((params.shortreads.paired) && (params.shortreads.single == '')) {
    parameter = "-1 $sread1 -2 $sread2"
    rid = sread1.getSimpleName()
    x = "Executing assembly with paired end reads"
  }
  """
  unicycler $parameter \\
  -o unicycler_illuminaOnly_results_${rid} -t ${params.threads} \\
  ${additionalParameters['Unicycler']} &>unicycler.log
  """
}

/*
 * STEP 2 - ASSEMBLY POLISHING
 */

// Create a single value channel to make polishing step wait for assemblers to finish
/*
[unicycler_ok, unicycler_ok2] = ((params.try.unicycler) && params.pacbio.all.baxh5.path == '' && params.fast5Path == '') ? Channel.empty().mix(unicycler_execution) : Channel.value('OK')
[canu_ok, canu_ok2] = ((params.try.canu) && params.pacbio.all.baxh5.path == '' && params.fast5Path == '') ? Channel.empty().mix(canu_execution) : Channel.value('OK')
[flye_ok, flye_ok2] = ((params.try.flye) && params.pacbio.all.baxh5.path == '' && params.fast5Path == '') ? Channel.empty().mix(flye_execution) : Channel.value('OK')
[nanopolish_ok, nanopolish_ok2] = (params.fast5Path) ? Channel.empty().mix(nanopolish_execution) : Channel.value('OK')
[variantCaller_ok, variantCaller_ok2] = (params.pacbio.all.baxh5.path) ? Channel.empty().mix(variant_caller_execution) : Channel.value('OK')
*/

/*
 * Whenever the user have paired end shor reads, this pipeline will execute
 * the polishing step with Unicycler polish pipeline.
 *
 * Unicycler Polishing Pipeline
 */

//Load contigs
if (params.pacbio.all.baxh5.path != '' && (params.shortreads.paired) && params.illumina_polish_longreads_contigs == true) {
 Channel.empty().mix(variant_caller_contigs).set { unicycler_polish }
} else if (params.fast5Path && (params.shortreads.paired) && params.illumina_polish_longreads_contigs == true) {
 Channel.empty().mix(nanopolished_contigs).set { unicycler_polish }
} else if (params.pacbio.all.baxh5.path == '' && params.fast5Path == '' && (params.shortreads.paired) && params.illumina_polish_longreads_contigs == true) {
 Channel.empty().mix(flye_contigs, canu_contigs, unicycler_longreads_contigs).set { unicycler_polish }
} else { Channel.empty().set {unicycler_polish} }

//Loading reads for quast
short_reads_lreads_polish = (params.shortreads.paired) ? Channel.fromFilePairs( params.shortreads.paired, flat: true, size: 2 )
                                                       : Channel.value(['', '', ''])
process illumina_polish_longreads_contigs {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:Unicycler_Polish'
  cpus threads

  input:
  each file(draft) from unicycler_polish.collect()
  set val(id), file(sread1), file(sread2) from short_reads_lreads_polish

  output:
  file("${assembler}_lreadsOnly_exhaustive_polished")
  file("${assembler}_lreadsOnly_exhaustive_polished/${assembler}_final_polish.fasta") into unicycler_polished_contigs

  when:
  (assembly_type == 'longreads-only' && (params.illumina_polish_longreads_contigs) && (params.shortreads.paired))

  script:
  if (draft.getName()  == 'assembly.fasta' || draft.getName() =~ /unicycler/) {
    assembler = 'unicycler'
  } else if (draft.getName()  == 'assembly_flye.fasta' || draft.getName() =~ /flye/) {
    assembler = 'flye'
  } else { assembler = 'canu' }
  """
  mkdir ${assembler}_lreadsOnly_exhaustive_polished;
  unicycler_polish --ale /home/ALE/src/ALE --samtools /home/samtools-1.9/samtools --pilon /home/pilon/pilon-1.23.jar \
  -a $draft -1 $sread1 -2 $sread2 --threads $threads &> polish.log ;
  mv 0* polish.log ${assembler}_lreadsOnly_exhaustive_polished;
  mv ${assembler}_lreadsOnly_exhaustive_polished/*_final_polish.fasta ${assembler}_lreadsOnly_exhaustive_polished/${assembler}_final_polish.fasta;
  """
}

/*
 * Whenever the user have unpaired short reads, this pipeline will execute
 * the polishing step with a single Pilon round pipeline.
 *
 * Unicycler Polishing Pipeline
 */
//Load contigs
if (params.pacbio.all.baxh5.path != '' && (params.shortreads.single) && params.illumina_polish_longreads_contigs == true) {
Channel.empty().mix(variant_caller_contigs).set { pilon_polish }
} else if (params.fast5Path && (params.shortreads.single) && params.illumina_polish_longreads_contigs == true) {
Channel.empty().mix(nanopolished_contigs).set { pilon_polish }
} else if (params.pacbio.all.baxh5.path == '' && params.fast5Path == '' && (params.shortreads.single) && params.illumina_polish_longreads_contigs == true) {
Channel.empty().mix(flye_contigs, canu_contigs, unicycler_longreads_contigs).set { pilon_polish }
} else { Channel.empty().set { pilon_polish } }

//Load reads
short_reads_pilon_single = (params.shortreads.single) ?
                     Channel.fromPath(params.shortreads.single) : ''

process pilon_polish {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:ASSEMBLERS'
  cpus threads

  input:
  each file(draft) from pilon_polish.collect()
  file(sread) from short_reads_pilon_single

  output:
  file "pilon_results_${assembler}/pilon*"
  file("pilon_results_${assembler}/pilon*.fasta") into pilon_polished_contigs

  when:
  (assembly_type == 'longreads-only' && (params.illumina_polish_longreads_contigs) && (params.shortreads.single))

  script:
  parameter = "$sread"
  rid = sread.getSimpleName()
  x = "Polishing assembly with single end reads"

  if (draft.getName()  == 'assembly.fasta' || draft.getName() =~ /unicycler/) {
    assembler = 'unicycler'
  } else if (draft.getName()  == 'assembly_flye.fasta' || draft.getName() =~ /flye/) {
    assembler = 'flye'
  } else { assembler = 'canu' }
  """
  bwa index ${draft} ;
  bwa mem -M -t ${params.threads} ${draft} $parameter > ${rid}_${assembler}_aln.sam ;
  samtools view -bS ${rid}_${assembler}_aln.sam | samtools sort > ${rid}_${assembler}_aln.bam ;
  samtools index ${rid}_${assembler}_aln.bam ;
  java -Xmx${params.pilon.memmory.limit}G -jar /miniconda/share/pilon-1.22-1/pilon-1.22.jar \
  --genome ${draft} --bam ${rid}_${assembler}_aln.bam --output pilon_${assembler}_${rid} \
  --outdir pilon_results_${assembler} ${additionalParameters['Pilon']} &>pilon.log
  """
}

/*
 * STEP 3 -  Assembly quality assesment with QUAST
 */

//Load contigs
if (params.illumina_polish_longreads_contigs) {
  Channel.empty().mix(unicycler_polished_contigs, pilon_polished_contigs).set { final_assembly }
} else if (params.pacbio.all.baxh5.path != '' && params.illumina_polish_longreads_contigs == false ) {
  Channel.empty().mix(variant_caller_contigs).set { final_assembly }
} else if (params.fast5Path && params.illumina_polish_longreads_contigs == false ) {
  Channel.empty().mix(nanopolished_contigs).set { final_assembly }
} else { Channel.empty().mix(unicycler_polish, spades_hybrid_contigs, unicycler_hybrid_contigs, unicycler_illumina_contigs, spades_illumina_contigs).set { final_assembly } }
//Loading reads for quast
short_reads_quast_single = (params.shortreads.single) ? Channel.fromPath(params.shortreads.single) : ''
short_reads_quast_paired = (params.shortreads.paired) ? Channel.fromFilePairs( params.shortreads.paired, flat: true, size: 2 )
                                                      : Channel.value(['', '', ''])
long_reads_quast = (params.longreads) ? Channel.fromPath(params.longreads) : ''

process quast {
  publishDir outdir, mode: 'copy'
  container 'fmalmeida/compgen:QUAST'

  input:
  each file(contigs) from final_assembly
  file 'reference_genome' from ref_genome
  file('sread') from short_reads_quast_single
  file('lreads') from long_reads_quast
  set val(id), file('pread1'), file('pread2') from short_reads_quast_paired

  output:
  file "quast_${type}_outputs_${assembler}/*"

  script:
  if ((params.shortreads.single) && (params.shortreads.paired) && assembly_type != 'longreads-only') {
    ref_parameter = "-M -t ${params.threads} reference_genome sread pread1 pread2"
    parameter = "-M -t ${params.threads} ${contigs} pread1 pread2"
    x = "Assessing assembly with paired and single end reads"
    sreads_parameter = "--single sread"
    preads_parameter = "--pe1 pread1 --pe2 pread2"
    lreads_parameter = ""
  } else if ((params.shortreads.single) && (params.shortreads.paired == '') && assembly_type != 'longreads-only') {
    ref_parameter = "-M -t ${params.threads} reference_genome sread"
    parameter = "-M -t ${params.threads} ${contigs} sread"
    x = "Assessing assembly with single end reads"
    sreads_parameter = "--single sread"
    preads_parameter = ""
    lreads_parameter = ""
  } else if ((params.shortreads.paired) && (params.shortreads.single == '') && assembly_type != 'longreads-only') {
    ref_parameter = "-M -t ${params.threads} reference_genome pread1 pread2"
    parameter = "-M -t ${params.threads} ${contigs} pread1 pread2"
    x = "Assessing assembly with paired end reads"
    sreads_parameter = ""
    preads_parameter = "--pe1 pread1 --pe2 pread2"
    lreads_parameter = ""
  } else if (assembly_type == 'longreads-only') {
    ltype = (params.lr_type == 'nanopore') ? "ont2d" : "pacbio"
    parameter = "-x ${ltype} -t ${params.threads} ${contigs} lreads"
    ref_parameter = "-x ${ltype} -t ${params.threads} reference_genome lreads"
    x = "Assessing assembly with long reads"
    sreads_parameter = ""
    preads_parameter = ""
    lreads_parameter = "--${params.lr_type} lreads"
  }
  if (contigs.getName()  == 'assembly.fasta' || contigs.getName() =~ /unicycler/) {
    assembler = 'unicycler'
  } else if (contigs.getName()  == 'contigs.fasta' || contigs.getName() =~ /spades/) {
    assembler = 'spades'
  } else if (contigs.getName()  == 'assembly_flye.fasta' || contigs.getName() =~ /flye/) {
    assembler = 'flye'
  } else { assembler = 'canu' }

  if (assembly_type == 'longreads-only') {
    type = 'lreadsOnly'
  } else if (assembly_type == 'illumina-only') {
    type = 'illuminaOnly'
  } else if (assembly_type == 'hybrid') {
    type = 'hybrid'
  }
  if (params.ref_genome != '')
  """
  bwa index reference_genome ;
  bwa index ${contigs} ;
  bwa mem $parameter > contigs_aln.sam ;
  bwa mem $ref_parameter > reference_aln.sam ;
  quast.py -o quast_${type}_outputs_${assembler} -t ${params.threads} --ref-sam reference_aln.sam --sam contigs_aln.sam \\
  $sreads_parameter $preads_parameter $lreads_parameter -r reference_genome --circos ${contigs}
  """
  else
  """
  bwa index ${contigs} ;
  bwa mem $parameter > contigs_aln.sam ;
  quast.py -o quast_${type}_outputs_${assembler} -t ${params.threads} --sam contigs_aln.sam \\
  $sreads_parameter $preads_parameter $lreads_parameter --circos ${contigs}
  """
}


// Completition message
workflow.onComplete {
    println "Pipeline completed at: $workflow.complete"
    println "Execution status: ${ workflow.success ? 'OK' : 'failed' }"
    println "Execution duration: $workflow.duration"
    // Remove work dir
    file('work').deleteDir()
}
/*
 * Header log info
 */
log.info "========================================="
log.info "     Docker-based assembly Pipeline      "
log.info "========================================="
def summary = [:]
summary['Long Reads']   = params.longreads
summary['Fast5 files dir']   = params.fast5Path
summary['Long Reads']   = params.longreads
summary['Short single end reads']   = params.shortreads.single
summary['Short paired end reads']   = params.shortreads.paired
summary['Fasta Ref']    = params.ref_genome
summary['Output dir']   = params.outDir
summary['Assembly assembly_type chosen'] = params.assembly_type
summary['Long read sequencing technology'] = params.lr_type
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Command used']   = "$workflow.commandLine"
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="