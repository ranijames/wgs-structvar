#!/usr/bin/env nextflow

/*
WGS Structural Variation Pipeline
*/

// 0. Pre-flight checks

if (params.help) {
    usage_message()
    exit 0
}

if (!params.bam) {
    exit 1, 'You need to specify a bam file, see --help for more information'
}

bamfile = file(params.bam)

if (! bamfile.exists()) {
    exit 1, "The bamfile, '$params.bam', does not exist"
}


if (!params.project) {
    exit 1, 'You need to specify what project to run under, see --help for more information'
}


workflowSteps = processWorkflowSteps(params.steps)


startup_message()

// 1. Run manta

// Try to guess location of bamindex file. If we can't find it create it
// else put that in the bamfile_index channel.

bamindex = infer_bam_index_from_bam()
if (!bamindex) {
    process index_bamfile {
        input:
            file 'bamfile' from bamfile
        output:
            file 'bamfile.bai' into bamfile_index

        module 'bioinfo-tools'
        module "$params.modules.samtools"

        // We only need one core for this part
        executor choose_executor()
        queue 'core'
        time params.short_job

        when: 'indexbam' in workflowSteps

        script:
        """
        samtools index bamfile
        """
    }
}
else {
    // The bamfile file already exists, put it in the channel.
    Channel.fromPath( bamindex ).set { bamfile_index }
}

process manta {
    input:
        file 'bamfile_tmp' from bamfile
        file 'bamfile.bai' from bamfile_index
    output:
        file 'manta.bed' into manta_bed
        file 'manta.vcf' into manta_vcf

    publishDir params.outdir, mode: 'copy'

    module 'bioinfo-tools'
    module "$params.modules.manta"

    errorStrategy { task.exitStatus == 143 ? 'retry' : 'terminate' }
    time { params.long_job * 2**task.attempt }
    maxRetries 3
    queue 'core'
    cpus 4

    when: 'manta' in workflowSteps

    script:
    """
    configManta.py --normalBam bamfile --referenceFasta $params.ref_fasta --runDir testRun
    cd testRun
    ./runWorkflow.py -m local -j $params.threads
    mv results/variants/diploidSV.vcf.gz ../manta.vcf.gz
    cd ..
    gunzip -c manta.vcf.gz > manta.vcf
    SVvcf2bed.pl manta.vcf > manta.bed
    """
}


// 2. Run fermikit

// Try to guess location of fastq file. If we can't find it create it
// else put that in the fastq channel.
if (!params.fastq) {
    params.fastq = infer_fastq_from_bam()
}

if (!params.fastq) {
    process create_fastq {
        input:
            file 'bamfile' from bamfile

        output:
            file 'fastq.fq.gz' into fastq

        module 'bioinfo-tools'
        module "$params.modules.samtools"

        // We only need one core for this part
        executor choose_executor()
        queue 'core'
        time params.short_job

        when: 'fastq' in workflowSteps

        script:
        """
        samtools bam2fq bamfile | gzip - > fastq.fq.gz
        """
    }
}
else {
    // The fastq file already exists, put it in the channel.
    Channel.fromPath( params.fastq ).set { fastq }
}

process fermikit {
    input:
        file 'sample.fq.gz' from fastq
    output:
        file 'fermikit.bed' into fermi_bed
        file 'fermikit.vcf' into fermi_vcf

    publishDir params.outdir, mode: 'copy'

    module 'bioinfo-tools'
    module "$params.modules.fermikit"
    module "$params.modules.samtools"
    module "$params.modules.vcftools"
    module "$params.modules.tabix"

    when: 'fermikit' in workflowSteps

    script:
    """
    fermi2.pl unitig -s$params.genome_size -t$params.threads -l$params.readlen -p sample sample.fq.gz > sample.mak
    make -f sample.mak
    run-calling -t$params.threads $params.ref_fasta sample.mag.gz > calling.sh
    bash calling.sh
    vcf-sort -c sample.sv.vcf.gz > fermikit.vcf
    bgzip -c fermikit.vcf > fermikit.vcf.gz
    SVvcf2bed.pl fermikit.vcf > fermikit.bed
    """
}



// 3. Create summary files

// Collect vcfs and beds into one channel
beds = manta_bed.mix( fermi_bed )
vcfs = manta_vcf.mix( fermi_vcf )


mask_files = [
    "$baseDir/data/ceph18.b37.lumpy.exclude.2014-01-15.bed",
    "$baseDir/data/LCR-hs37d5.bed.gz"
]

masks = mask_files.collect { file(it) }.channel()
// Collect both bed files and combine them with the mask files
beds.spread( masks.buffer(size: 2) ).set { mask_input }

process mask_beds {
    input:
        set file(bedfile), file(mask1), file(mask2) from mask_input
    output:
        file '*_masked.bed' into masked_beds

    publishDir params.outdir, mode: 'copy'

    // Does not use many resources, run it locally
    executor choose_executor()
    queue 'core'
    time params.short_job

    module 'bioinfo-tools'
    module "$params.modules.bedtools"

    """
    BNAME=\$( echo $bedfile | cut -d. -f1 )
    MASK_FILE=\${BNAME}_masked.bed
    cat $bedfile \
        | bedtools intersect -v -a stdin -b $mask1 -f 0.25 \
        | bedtools intersect -v -a stdin -b $mask2 -f 0.25 > \$MASK_FILE
    """
}


// To make intersect files we need to combine them into one channel with
// toList(). And also figure out if we have one or two files, therefore the
// tap and count_beds.
masked_beds.tap { count_beds_tmp }
           .tap { masked_beds }
           .toList().set { intersect_input }
count_beds_tmp.count().set { count_beds }

process intersect_files {
    input:
        set file(bed1), file(bed2) from intersect_input
        val nbeds from count_beds
    output:
        file "combined_masked.bed" into intersections

    publishDir params.outdir, mode: 'copy'

    // Does not use many resources, run it locally
    executor choose_executor()
    queue 'core'
    time params.short_job

    module 'bioinfo-tools'
    module "$params.modules.bedtools"

    when: nbeds == 2

    script:
    """
    ## In case grep doesn't find anything it will exit with non-zero exit
    ## status, which will cause slurm to abort the job, we want to continue on
    ## error here.
    set +e

    ## Create intersected bed files
    for WORD in DEL INS DUP; do
        intersectBed -a <( grep -w \$WORD $bed1 ) -b <( grep -w \$WORD $bed2 ) \
            -f 0.5 -r \
            | sort -k1,1V -k2,2n > combined_masked_\${WORD,,}.bed
    done

    cat <( grep -v -w 'DEL\\|INS\\|DUP' $bed1 ) \
        <( grep -v -w 'DEL\\|INS\\|DUP' $bed2 ) \
        | sort -k1,1V -k2,2n > combined_masked_OTHER.bed

    sort -k1,1V -k2,2n combined_masked_*.bed >> combined_masked.bed

    set -e # Restore exit-settings
    """
}

annotate_files = intersections.flatten().mix( masked_beds.tap { masked_beds } )

process variant_effect_predictor {
    input:
        file infile from annotate_files.tap { annotate_files }
    output:
        file '*.vep' into vep_outfiles

    publishDir params.outdir, mode: 'copy'

    executor choose_executor()
    queue 'core'
    time params.short_job

    module 'bioinfo-tools'
    module "$params.modules.vep"

    when: 'vep' in workflowSteps

    script:
    """
    infile="$infile"
    outfile="\$infile.vep"
    vep_cache="/sw/data/uppnex/vep/84"
    assembly="$params.vep.assembly"

    case "\$infile" in
        *vcf) format="vcf" ;;
        *bed) format="ensembl" ;;
        *)    printf "Unrecognized format for '%s'" "\$infile" >&2
              exit 1;;
    esac

    variant_effect_predictor.pl \
        -i "\$infile"              \
        --format "\$format"        \
        -cache --dir "\$vep_cache" \
        -o "\$outfile"             \
        --vcf                      \
        --merged                   \
        --regulatory               \
        --force_overwrite          \
        --sift b                   \
        --polyphen b               \
        --symbol                   \
        --numbers                  \
        --biotype                  \
        --total_length             \
        --canonical                \
        --ccds                     \
        --fields Consequence,Codons,Amino_acids,Gene,SYMBOL,Feature,EXON,PolyPhen,SIFT,Protein_position,BIOTYPE \
        --assembly "\$assembly" \
        --offline
    """
}

process snpEff() {
    input:
        file vcf from vcfs_snpeff
    output:
        file '*snpeff_genes.txt'
        file '*.snpeff'

    publishDir params.outdir, mode: 'copy'

    module 'bioinfo-tools'
    module "$params.modules.snpeff"

    // Does not use many resources, run it locally
    executor choose_executor()
    queue 'core'
    time params.short_job

    when: 'snpeff' in workflowSteps

    script:
    """
    vcf="$vcf" ## Use bash-semantics for variables
    snpeffjar=''

    for p in \$( tr ':' ' ' <<<"\$CLASSPATH" ); do
        if [ -f "\$p/snpEff.jar" ]; then
            snpeffjar="\$p/snpEff.jar"
            break
        fi
    done
    if [ -z "\$snpeffjar" ]; then
        printf "Can't find snpEff.jar in '%s'" "\$CLASSPATH" >&2
        exit 1
    fi

    sed 's/ID=AD,Number=./ID=AD,Number=R/' "\$vcf" \
        | vt decompose -s - \
        | vt normalize -r $params.ref_fasta - \
        | java -Xmx7G -jar "\$SNPEFFJAR" -formatEff -classic GRCh37.75 \
        > "\$vcf.snpeff"

    cp snpEff_genes.txt "\$vcf.snpeff_genes.txt"
    """
}


// Utility functions

def usage_message() {
    log.info ''
    log.info 'Usage:'
    log.info '    nextflow main.nf --bam <bamfile> [more options]'
    log.info ''
    log.info 'Options:'
    log.info '  Required'
    log.info '    --bam           Input bamfile'
    log.info '    --project       Uppmax project to log cluster time to'
    log.info '  Optional'
    log.info '    --help          Show this message and exit'
    log.info '    --fastq         Input fastqfile (default is bam but with fq as fileending)'
    log.info '    --steps         Specify what steps to run, comma separated:'
    log.info '                Callers: manta, fermikit, cnvnator (choose one or many)'
    log.info '                Annotation: vep OR snpeff'
    log.info '    --long_job      Running time for long job (callers, fermi and manta)'
    log.info '    --short_job     Running time for short jobs (bam indexing and bam2fq)'
    log.info '    --outdir        Directory where resultfiles are stored'
    log.info ''
}

def startup_message() {
    revision = grab_git_revision()

    log.info "======================"
    log.info "WGS-structvar pipeline"
    log.info "======================"
    log.info "Bamfile    : $params.bam"
    log.info "Scriptdir  : $baseDir"
    log.info "Revision   : $revision"
    log.info "Work dir   : $workDir"
    log.info "Output dir : $params.outdir"
    log.info "Project    : $params.project"
    log.info "Will run   : " + workflowSteps.join(", ")
    log.info ""
}

def grab_git_revision() {
    if ( workflow.commitId ) { // it's run directly from github
        return workflow.commitId
    }

    // Try to find the revision directly from git
    head_pointer_file = file("${baseDir}/.git/HEAD")
    if ( ! head_pointer_file.exists() ) {
        return ''
    }
    ref = head_pointer_file.newReader().readLine().tokenize()[1]

    ref_file = file("${baseDir}/.git/$ref")
    if ( ! ref_file.exists() ) {
        return ''
    }
    revision = ref_file.newReader().readLine()

    return revision
}

def infer_bam_index_from_bam() {
    // If the ".bam.bai" file does not exist, try ".bai" without ".bam"
    return infer_filepath(params.bam, /$/, '.bai')
        ?: infer_filepath(params.bam, /.bam$/, '.bai')
}

def infer_fastq_from_bam() {
    return infer_filepath(params.bam, /.bam$/, '.fq.gz')
}

def infer_filepath(from, match, replace) {
    path = file( from.replaceAll(match, replace) )
    if (path.exists()) {
        return path
    }
    return false
}

def nextflow_running_as_slurmjob() {
    if ( System.getenv()["SLURM_JOB_ID"] ) {
        return true
    }
    return false
}

def choose_executor() {
    return nextflow_running_as_slurmjob() ? 'local' : 'slurm'
}

def processWorkflowSteps(steps) {
    if ( ! steps ) {
        return []
    }

    workflowSteps = steps.split(',').collect { it.trim().toLowerCase() }

    if ('vep' in workflowSteps && 'snpeff' in workflowSteps) {
        exit 1, 'You can only run one annotator, either "vep" or "snpeff"'
    }

    if ('manta' in workflowSteps) {
        workflowSteps.push( 'indexbam' )
    }

    if ('fermikit' in workflowSteps) {
        workflowSteps.push( 'fastq' )
    }

    return workflowSteps
}
