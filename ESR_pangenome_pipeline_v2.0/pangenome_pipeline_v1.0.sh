#!/bin/bash 

#this pipeline is 1) using whole genomes as input for constructing Pangenome graph, which encoded in the variation graph data model describe the all versus all alignment of many sequences  
#                 2) manupilate the graph, such as annotation, visulaition and extract subregions 
#                 3) mapping short reads to graph, get Gam files
#                 4) call variant using the Gam files either using genotying or including novel variants
#The variants called from graph based gam files can be used for further standard analysis as variants called agaist single linear refs.
#also see https://pangenome.github.io/


#software and versions using in the this pipeline 
# Mash version 2.1  to calculate the distance for the genomes, which can be used as a guide for the similary -p for building the Pangenome graph
# pggb version 0.3.0 for pangenome graph building  https://github.com/pangenome/pggb  Erik's team is keeping improve pggb  
# pgge https://github.com/pangenome/pgge 
# odgi version 0.6.2 provides a set of tools ranging from graph building, manipulation, layouting, over graph statistics to graph visualization and gene annotation lift overs
# https://github.com/pangenome/odgi
# vg version 1.37.0  provides computational methods for creating and manipulating of genome variation graphs. It's pangenome representation of a set of genomes overcomes reference bias and improves read mapping.
# circlator version 1.5.5
# samtools version 1.9

# as our admin installed all those tools as singularity on our server
# so load module that needed to be use 

module load mash/2.1 
module load circlator/1.5.5 
module load pggb/0.3.0
module load odgi/0.6.2 
module load vg/1.37.0
module load samtools/1.9
module load pgge/20210412

#prepare fasta file before graph building 
#Using circlator fixstart to change start position of circular sequences
circlator fixstart [options] <assembly.fasta> <outprefix>

#cat all sequences used for graph building together 
cat sample1.fasta sample2.fasta ... >samples.fa

#samtools faidx build index for samples.fa 
samtools faidx samples.fa 

#using mash triange to calculate the distance for the genomes 

mash triangle [options] <seq1> [<seq2>] ...


#my following example contains four genomes which are NC_017518 NMI01191_mut_indel200Inv2 NMI97349_mut_indel200Inv2 NC_017518_5KSNPs_indels200Inv2i, named as 4Sim 

#Building the pangenome graph
# -s segment length for mapping 
# -p percent identity for mapping/alignment 
# -n the number of mappings to retain for each segment
# -t number of compute threads to use in parallel steps
# -S generate statistics of the seqwish and smoothxg graph
# -m generate MultiQC report of graphs' statistics and visualizations, automatically runs odgi stats
# -o output directory  
# try different setting for -s and -p to see if there is any difference
# choose one the best pangenome graph for further step 
pggb -i $input_path/4Sim.fa -N -s 50000 -p 95 -n 4 -t 16 -S -m -o $output_path/4Sim_50K0.95

#check the mutilqc results 
#and run pgge to see which setting is relative better than others
#$inpput.gfa generated by pggb
#$input.fa is the fasta file used for pangenome graph building  
pgge -g $input_path/4Sim_50K0.95.smooth.fix.gfa -f $input_path/4Sim.fa -o $output -r $path/pgge/scripts/beehave.R -b $output/pgge_4Sim_50K0.95_peanut_bed -l 100000 -s 5000 -t 16


#once choose the best pggb result, can process further 
#annotate the graph based paths
#using vg deconstruct to get the variantion among the paths of the graph 
#check the variants


#annotation
#gfaestus, also uses BED and GFF3 files against the paths in the graph
#https://github.com/chfi/gfaestus
#once you got gfaestus installed 
#Use gfaestus to view graph in 2D, go to the gfaestus folder
./gfaestus ./${x}.gfa
#load bed file of annotation 


#visulizatio a specific region using odgi
odgi viz -i 4Sim_50K0.95.smooth.fix.gfa -r NC_017518:50000-1000000  -o test_range.png


#deconstruct the graph for paths to get variants among the paths

vg deconstruct -p NC_017518 -p NMI01191_mut_indel200Inv2 -p NMI97349_mut_indel200Inv2 -p NC_017518_5KSNPs_indels200Inv2  4Sim_50K0.95.smooth.fix.gfa -a > 4Sim50k0.95_dec_a.vcf


#build index of graph .gfa for NGS data mapping 
odgi sort -i 4Sim_50K0.95.smooth.fix.gfa -o - -p Ygs -P | odgi view -i - -g >4Sim_50k0.95_sorted_graph.gfa

#convert the graph into 256 bp chunks
vg mod -X 256 4Sim_50k0.95_sorted_graph.gfa > 4Sim_50k0.95_sorted_graph_256.vg
vg index -t 48 -x 4Sim_50k0.95_sorted_graph_256.xg -g 4Sim_50k0.95_sorted_graph_256.gcsa -k 16 4Sim_50k0.95_sorted_graph_256.vg


#map NGS short reads to Graph
index=$path/4Sim_50k0.95_sorted_graph_256.gcsa
basename=$path/4Sim_50k0.95_sorted_graph_256
x=NGS_data_sample_IDs
vg map -t 20  -d $basename -g $index  -f $input_folder/$read1 -f $input_folder/$read2 -N $x  > $output/${x}vgmap_4Sim.gam
vg stats -a  $output/${x}vgmap_4Sim.gam  >$output/${x}vgmap_4Sim_stats


#call variant 1, based on snarls in the graph, without novel variants

#compute snarls
vg snarls $graph_xg >$snarls_file

#Calculate the surpport reads ingoring mapping and base quality <5
vg pack -t 48 -x $graph_xg -g $path/${x}_4Sim.gam -Q 5 -o $path/${x}vgmap_Sim4_256_aln.pack

#call variant using the same coordinates and including reference calls (for following compare), reads >=10, support of variant Reads >= 3
vg call -t 60 -m 3,10 $graph_xg -k $path/${x}vgmap_Sim4_256_aln.pack -r $snarls_file  >$path/${x}vgmap_Sim4_256_aln.pack_R10S3.vcf


#call variant 2, 
#in order to also consider novel variants from the reads, use the augmented graph and gam (as created in the "Augmentation" example using vg augment -A)
#Augment augment the graph with all variation from the GAM, saving to aug.vg
### augment the graph with all variation from the GAM execept that implied by soft clips, saving to aug.vg
### *aug-gam contains the same reads as aln.gam but mapped to aug.vg

vg augment -t 48 $graph_vg $path/${x}.vgmap_4Sim.gam -A $path/${x}nofilt_aug.gam >$path/${x}nofilt_aug.vg

#index the augmented graph
vg index -t 48 $path/${x}nofilt_aug.vg -x $path/${x}nofilt_aug.xg

## Compute the read support from the augmented gam
vg pack -t 60 -x $path/${x}nofilt_aug.xg -g $path/${x}nofilt_aug.gam  -o $path/${x}nofilt_aug_allR.pack

#call variant
vg call -t 60 -m 3,10 $path/${x}nofilt_aug.xg -k $path/${x}nofilt_aug_allR.pack >$path/${x}nofilt_aug_allR.pack.vcf


