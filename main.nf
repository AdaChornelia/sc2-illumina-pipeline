def helpMessage() {
  log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run main.nf --reads '*_R{1,2}_001.fastq.gz' --ref reference.fasta --primers primers.bed

    Mandatory arguments:
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.
      --reads                       Path to reads, must be in quotes
      --primers                     Path to BED file of primers (default: data/SARS-COV-2_spikePrimers.bed)
      --ref                         Path to FASTA reference sequence (default: data/MN908947.3.fa)
      --ref_host                    Path to FASTA for host reference genome (default: data/human_chr1.fa)

    Consensus calling options:
      --kraken2_db                  Path to kraken db (default: "")
      --exclude_samples             comma-separated string of samples to exclude from analysis
      --single_end [bool]           Specifies that the input is single-end reads
      --skip_trim_adapters [bool]   Skip trimming of illumina adapters. (NOTE: this does NOT skip the step for trimming spiked primers)
      --skip_filter_ref             Skip host-filtering.
      --maxNs                       Max number of Ns to allow assemblies to pass QC
      --minLength                   Minimum base pair length to allow assemblies to pass QC
      --no_reads_quast              Run QUAST without aligning reads
      --ercc_fasta                  Default: data/ercc_sequences.fasta
      --save_sars2_filtered_reads   Whether to save the reads filtered down to just SARS-CoV-2

    Other options:
      --outdir                      The output directory where the results will be saved
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
      -resume                       Use cached results

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}


// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

multiqc_config = file(params.multiqc_config, checkIfExists: true)

ref_fasta = file(params.ref, checkIfExists: true)
ref_host = file(params.ref_host, checkIfExists: true)
primer_bed = file(params.primers, checkIfExists: true)

if (params.readPaths) {
    if (params.single_end){
	Channel
	.fromList(params.readPaths)
	.map { row -> [ row[0], [ file(row[1][0], checkIfExists: true)] ] }
	.set { reads_ch }
    } else {
	Channel
	.fromList(params.readPaths)
	.map { row -> [ row[0], [ file(row[1][0], checkIfExists: true), file(row[1][1], checkIfExists: true) ] ] }
	.set { reads_ch }
    }
} else {
    Channel
	.fromFilePairs(params.reads, size: params.single_end ? 1 : 2)
	.set { reads_ch }
}

// remove excluded samples from reads_ch
exclude_samples = params.exclude_samples.split(",")
reads_ch = reads_ch.filter { !exclude_samples.contains(it[0]) }

reads_ch.into { unaligned_reads; stats_reads; ercc_in}
reads_ch = unaligned_reads

if (params.skip_filter_ref) {
    // skip trimming
    reads_to_remove_host_in = Channel.empty()
} else {
    // send reads to host filtering, and empty the reads channel
    reads_to_remove_host_in = reads_ch
    reads_ch = Channel.empty()
}

process filterRefReads {
    tag { sampleName }
    label 'process_large'
    publishDir "${params.outdir}/filtered-reads"

    input:
    path(ref_host)
    tuple(sampleName, file(reads)) from reads_to_remove_host_in

    output:
    tuple(sampleName, file("${sampleName}_no_host_*.fq.gz")) into reads_host_removed_out

    script:
    """
    minimap2 -t ${task.cpus-1} -ax sr ${ref_host} ${reads} | \
    samtools view -@ ${task.cpus-1} -b -f 4 | \
    samtools fastq -@ ${task.cpus-1} -1 ${sampleName}_no_host_1.fq.gz -2 ${sampleName}_no_host_2.fq.gz -0 /dev/null -s /dev/null -n -c 6 -
    """
}

reads_ch = reads_ch.mix(reads_host_removed_out)

if (params.kraken2_db) {
  // send reads to kraken, and empty the reads channel
  kraken2_reads_in = reads_ch
  reads_ch = Channel.empty()
  if (hasExtension(params.kraken2_db, 'gz')) {
    kraken2_db_gz = Channel
	.fromPath(params.kraken2_db, checkIfExists: true)
	.ifEmpty { exit 1, "Kraken2 database not found: ${params.kraken2_db}" }
  } else{
    kraken2_db = Channel
	.fromPath(params.kraken2_db, checkIfExists: true)
	.ifEmpty { exit 1, "Kraken2 database not found: ${params.kraken2_db}" }
  }
} else {
  // skip kraken
  kraken2_reads_in = Channel.empty()
  kraken2_db = Channel.empty()

}

if (hasExtension(params.kraken2_db, 'gz')) {
  process gunzip_kraken_db {
      tag "$gz"
      publishDir "${params.outdir}/kraken_db", mode: 'copy'

      input:
      file gz from kraken2_db_gz

      output:
      file "${gz.simpleName}" into kraken2_db

      script:
      // Use tar as the star indices are a folder, not a file
      """
      tar -xzvf ${gz}
      """
  }
}

ercc_fasta = file(params.ercc_fasta, checkIfExists: true)

process quantifyERCCs {
  tag {sampleName}
  publishDir "${params.outdir}/ercc-stats", mode: 'copy'
  label 'process_medium'

  input:
  path(ercc_fasta)
  tuple(sampleName, path(reads)) from ercc_in

  output:
  tuple(sampleName, path("${sampleName}.ercc_stats")) into ercc_out

  script:
  """
  minimap2 -t ${task.cpus-1} -ax sr ${ercc_fasta} ${reads} |
    samtools view -@ ${task.cpus-1} -bo ercc_mapped.bam
  samtools stats -@ ${task.cpus-1} ercc_mapped.bam > ${sampleName}.ercc_stats
  """
}

process filterReads {
    tag { sampleName }
    label 'process_large'
    // Don't create filtered-sars2-reads subfolder if flag not specified
    publishDir path: { params.save_sars2_filtered_reads ? "${params.outdir}/filtered-sars2-reads" : params.outdir },
      mode: 'copy',
      saveAs: { params.save_sars2_filtered_reads ? it : null }

    input:
    path(db) from kraken2_db.collect()
    path(ref_fasta)
    tuple(sampleName, file(reads)) from kraken2_reads_in

    output:
    tuple(sampleName, file("${sampleName}_covid_*.fq.gz")) into kraken2_reads_out

    script:
    """
    minimap2 -t ${task.cpus-1} -ax sr ${ref_fasta} ${reads} |
      samtools sort -@ ${task.cpus-1} -n -O bam -o mapped.bam
    samtools fastq -@ ${task.cpus-1} -G 12 -1 paired1.fq.gz -2 paired2.fq.gz \
       -0 /dev/null -s /dev/null -n -c 6 \
       mapped.bam
    rm mapped.bam

    LINES=\$(zcat paired1.fq.gz | wc -l)
    if [ "\$LINES" -gt 0 ];
    then
	kraken2 --db ${db} \
	  --threads ${task.cpus} \
	  --report ${sampleName}.kraken2_report \
	  --classified-out "${sampleName}_classified#.fq" \
	  --output - \
	  --memory-mapping --gzip-compressed --paired \
	  paired1.fq.gz paired2.fq.gz

	rm paired1.fq.gz paired2.fq.gz

	grep --no-group-separator -A3 "kraken:taxid|2697049" \
	     ${sampleName}_classified_1.fq \
	     > ${sampleName}_covid_1.fq || [[ \$? == 1 ]]

	grep --no-group-separator -A3 "kraken:taxid|2697049" \
	     ${sampleName}_classified_2.fq \
	     > ${sampleName}_covid_2.fq || [[ \$? == 1 ]]

	gzip ${sampleName}_covid_1.fq
	gzip ${sampleName}_covid_2.fq

	rm ${sampleName}_classified_*.fq
    else
	mv paired1.fq.gz ${sampleName}_covid_1.fq.gz
	mv paired2.fq.gz ${sampleName}_covid_2.fq.gz
    fi
    """
}

//send kraken output back to the reads channel
reads_ch = reads_ch.concat(kraken2_reads_out)

if (params.skip_trim_adapters) {
    // skip trimming
    trimgalore_reads_in = Channel.empty()
} else {
    // send reads to trim_galore, and empty the reads channel
    trimgalore_reads_in = reads_ch
    reads_ch = Channel.empty()
}

process trimReads {
    tag { sampleName }
    label 'process_medium'
    publishDir "${params.outdir}/trimmed-reads", mode: 'copy',
	saveAs: { x -> x.endsWith(".fq.gz") ? x : null }

    cpus 2

    input:
    tuple(sampleName, file(reads)) from trimgalore_reads_in

    output:
    tuple(sampleName, file("*_val_*.fq.gz")) into trimgalore_reads_out
    path("*") into trimmed_reports

    script:
    """
    LINES=\$(zcat ${reads[0]} | wc -l)
    if [ "\$LINES" -gt 0 ];
    then
	trim_galore --fastqc --paired ${reads}
	TRIMMED=\$(zcat ${sampleName}_covid_1_val_1.fq.gz | wc -l)
	if [ "\$TRIMMED" == 0 ];
	then
	    rm -r *fastqc.zip
	fi
    else
	cp ${reads[0]} ${sampleName}_covid_1_val_1.fq.gz
	cp ${reads[1]} ${sampleName}_covid_2_val_2.fq.gz
    fi
    """
}

// send trim_galore output back to the reads channel
reads_ch = reads_ch.concat(trimgalore_reads_out)

// send reads to minimap2 and quast
reads_ch.into { minimap2_reads_in; quast_reads }

process alignReads {
    tag { sampleName }
    label 'process_medium'

    input:
    tuple(sampleName, file(reads)) from minimap2_reads_in
    path(ref_fasta)

    output:
    tuple(sampleName, file("${sampleName}.bam")) into bam2trimPrimers

    script:
    """
    minimap2 -ax sr -R '@RG\\tID:${sampleName}\\tSM:${sampleName}' ${ref_fasta} ${reads} |
      samtools sort -@ ${task.cpus-1} -O bam -o ${sampleName}.bam
    """
}

process trimPrimers {
    tag { sampleName }
    label 'process_medium'
    publishDir "${params.outdir}/aligned-reads", mode: 'copy'

    input:
    tuple(sampleName, file(alignment)) from bam2trimPrimers
    path(primer_bed)

    output:
    tuple(sampleName, file("${sampleName}.primertrimmed.bam")) into trimmed_bam_ch;
    file("${sampleName}.primertrimmed.bam.bai")

    script:
    """
    samtools view -F4 -q ${params.samQualThreshold} -o ivar.bam ${alignment}
    samtools index ivar.bam
    ivar trim -e -i ivar.bam -b ${primer_bed} -p ivar.out
    samtools sort -O bam -o ${sampleName}.primertrimmed.bam ivar.out.bam
    samtools index ${sampleName}.primertrimmed.bam
    """
}

trimmed_bam_ch.into { quast_bam; consensus_bam; stats_bam;
                     call_variants_bam; combined_variants_bams }

process makeConsensus {
  tag { sampleName }
  publishDir "${params.outdir}/consensus-seqs", mode: 'copy'
  label 'process_pileup'

  input:
  tuple(sampleName, path(bam)) from consensus_bam

  output:
  tuple(sampleName, path("${sampleName}.consensus.fa")) into (consensus_fa, quast_ch)

  script:
  """
  samtools index ${bam}
  samtools mpileup -A -d 0 -Q0 ${bam} |
      ivar consensus -q ${params.ivarQualThreshold} -t ${params.ivarFreqThreshold} -m ${params.minDepth} -n N -p ${sampleName}.primertrimmed.consensus
  echo '>${sampleName}' > ${sampleName}.consensus.fa
  seqtk seq -l 50 ${sampleName}.primertrimmed.consensus.fa | tail -n +2 >> ${sampleName}.consensus.fa
  """
}


consensus_fa.into { quast_ch; stats_fa; merge_fastas_ch; realign_fa }
merge_fastas_ch = merge_fastas_ch.map { it[1] }

process quast {
   tag { sampleName }
   label 'process_medium'
   publishDir "${params.outdir}/QUAST", mode: 'copy'

   input:
   tuple(sampleName, path(assembly)) from quast_ch
   tuple(sampleName, path(bam)) from quast_bam
   tuple(sample, path(reads)) from quast_reads
   path(ref_fasta)

   output:
   // Avoid name clash with other samples for MultiQC
   path("${sampleName}/*") into multiqc_quast

   script:
   if (params.no_reads_quast)
   """
   run_quast.py --noreads --assembly ${assembly} --sample ${sampleName} --ref ${ref_fasta} \
    --threads ${task.cpus} --bam ${bam}
   """
   else
   """
   run_quast.py --noreads --assembly ${assembly} --sample ${sampleName} --ref ${ref_fasta} \
    --threads ${task.cpus} --bam ${bam} --R1 ${reads[0]} --R2 ${reads[1]}
   """
}

process callVariants {
    tag { sampleName }
    label 'process_pileup'
    publishDir "${params.outdir}/sample-variants", mode: 'copy'

    input:
    tuple(sampleName, path(in_bams)) from call_variants_bam
    path(ref_fasta)

    output:
    tuple(sampleName, path("${sampleName}.vcf.gz")) into (stats_vcf, individual_vcfs)
    path("${sampleName}.bcftools_stats") into bcftools_stats_ch
    path("${sampleName}.vcf.gz.tbi")

    // NOTE: we use samtools instead of bcftools mpileup because bcftools 1.9 ignores -d0
    script:
    """
    samtools mpileup -u -d 0 -t AD -f ${ref_fasta} ${in_bams} |
        bcftools call --ploidy 1 -m -P ${params.bcftoolsCallTheta} -v - |
        bcftools view -i 'DP>=${params.minDepth}' \
        > ${sampleName}.vcf
    bgzip ${sampleName}.vcf
    tabix ${sampleName}.vcf.gz
    bcftools stats ${sampleName}.vcf.gz > ${sampleName}.bcftools_stats
    """
}

stats_reads
    .join(stats_bam)
    .join(stats_fa)
    .join(ercc_out)
    .join(stats_vcf)
    .set { stats_ch_in }

process computeStats {
    tag { sampleName }
    label 'process_small'
    publishDir "${params.outdir}/coverage-plots", mode: 'copy',
	saveAs: { x -> x.endsWith(".png") ? x : null }

    input:
    tuple(sampleName,
	  file(reads),
	  file(trimmed_filtered_bam),
	  file(in_fa),
	  file(ercc_stats),
	  file(vcf)) from stats_ch_in

    output:
    file("${sampleName}.samtools_stats") into samtools_stats_out
    path("${sampleName}.stats.json") into stats_ch
    path("${sampleName}.depths.png")

    script:
    """
    samtools index ${trimmed_filtered_bam}
    samtools stats ${trimmed_filtered_bam} > ${sampleName}.samtools_stats
    alignment_assembly_stats.py \
	--sample_name ${sampleName} \
	--cleaned_bam ${trimmed_filtered_bam} \
	--ercc_stats ${ercc_stats} \
	--samtools_stats ${sampleName}.samtools_stats \
	--assembly ${in_fa} \
	--vcf ${vcf} \
	--out_prefix ${sampleName} \
	--reads ${reads}
    """
}

if (!params.joint_variant_calling) {
    combined_variants_bams = Channel.empty()
    individual_vcfs = Channel.empty()
} else {
    combined_variants_bams = combined_variants_bams.map { it[1] }.collect()
    individual_vcfs = individual_vcfs.map { it[1] }.collect()
}

process combinedVariants {
    publishDir "${params.outdir}", mode: 'copy'
    label 'process_large'

    input:
    path(in_bams) from combined_variants_bams
    path(vcfs) from individual_vcfs
    path(ref_fasta)

    output:
    path("combined.vcf") into combined_variants_vcf

    // NOTE: we use samtools instead of bcftools mpileup because bcftools 1.9 ignores -d0
    script:
    """
    printf "%s\\n" ${vcfs} | xargs -I % tabix %
    printf "%s\\n" ${in_bams} | xargs -I % samtools index %
    bcftools merge \$(printf "%s\n" ${vcfs}) | bcftools query -f '%CHROM\\t%POS\\n' > variant_positions.txt
    split -e -n l/${task.cpus} variant_positions.txt split_regions_
    ls split_regions_* |
        parallel -I % -j ${Math.ceil(task.cpus/2) as int} \
        'samtools mpileup -u -d 0 -t DP,AD -f ${ref_fasta} \
        -l % ${in_bams} |
        bcftools call --ploidy 1 -m -P ${params.bcftoolsCallTheta} -v - \
        > %.vcf'
    bcftools concat split_regions_*.vcf > combined.vcf
    """
}


process mergeAllAssemblies {
    publishDir "${params.outdir}", mode: 'copy'
    label 'process_tiny'

    input:
    path(in_fasta) from merge_fastas_ch.collect()

    output:
    path("combined.fa") into merged_assemblies_ch

    script:
    """
    cat ${in_fasta} > combined.fa
    """
}

process mergeAssemblyStats {
    publishDir "${params.outdir}/call_consensus-stats", mode: 'copy'
    label 'process_small'

    input:
    path(in_json) from stats_ch.collect()

    output:
    path("combined.stats.tsv") into merged_stats_ch

    script:
    """
    merge_stats.py core ${in_json} > combined.stats.tsv
    """
}

process filterAssemblies {
    publishDir "${params.outdir}", mode: 'copy',
      saveAs: {x -> x.endsWith(".tsv") ? "call_consensus-stats/$x" : x}
    label 'process_small'

    input:
    path(merged_stats) from merged_stats_ch
    path(merged_assemblies) from merged_assemblies_ch

    output:
    path("filtered.stats.tsv")
    path("filtered.fa") into nextstrain_ch

    script:
    """
    filter_assemblies.py \
	--max_n ${params.maxNs} --min_len ${params.minLength} \
	--stats ${merged_stats} --fasta ${merged_assemblies} \
	--out_prefix filtered
    """
}

process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'
    label 'process_medium'

    input:
    path(trim_galore_results) from trimmed_reports.collect().ifEmpty([])
    path("quast_results/*/*") from multiqc_quast.collect()
    path(samtools_stats) from samtools_stats_out.collect()
    path(bcftools_stats) from bcftools_stats_ch.collect().ifEmpty([])
    path(multiqc_config)

    output:
    path("*multiqc_report.html")
    path("*_data")
    path("multiqc_plots")

    // TODO: add trim_galore results (currently breaking for empty fastqs?)
    script:
    """
    multiqc -f -ip --config ${multiqc_config} \
	${samtools_stats} \
	quast_results/ \
	${trim_galore_results} \
	${bcftools_stats}
    """
}


// Check file extension
def hasExtension(it, extension) {
    it.toString().toLowerCase().endsWith(extension.toLowerCase())
}
