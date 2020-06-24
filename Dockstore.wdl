version 1.0

#
# WDL workflows for running population genetics simulations using cosi2
#

#
# TODO:
#
#   include metadata including selection start/stop/pop in workflow output as table
#   and muation age
#
#   figure out how to enable result caching without 
#

struct ReplicaInfo {
  String modelId
  String blockNum
  Int replicaNum
  Int succeeded
    Int         randomSeed
    File        tpeds
  File traj
  Int  selPop
  Float selGen
  Int selBegPop
  Float selBegGen
  Float selCoeff
  Float selFreq
}

task cosi2_run_one_sim_block {
  meta {
    description: "Run one block of cosi2 simulations for one demographic model."
    email: "ilya_shl@alum.mit.edu"
  }

  parameter_meta {
    # Inputs
    ## required
    paramFile: "parts cosi2 parameter file (concatenated to form the parameter file)"
    recombFile: "recombination map"
    simBlockId: "an ID of this simulation block (e.g. block number in a list of blocks)."

    ## optional
    nSimsInBlock: "number of simulations in this block"
    maxAttempts: ""

    # Outputs
    replicaInfos: "array of replica infos"
  }

  input {
    File         paramFileCommon
    File         paramFile
    File         recombFile
    String       simBlockId
    String       modelId
    Int          blockNum
    Int          nSimsInBlock = 1
    Int          maxAttempts = 10000000
    Int          randomSeed = 0
    String       cosi2_docker = "quay.io/ilya_broad/dockstore-tool-cosi2@sha256:11df3a646c563c39b6cbf71490ec5cd90c1025006102e301e62b9d0794061e6a"
  }

  command <<<
  python3 <<CODE

  import platform
  print(platform.version())

  CODE

  echo -e "modelId\tblockNum\treplicaNum\tsucceeded\trandomSeed\ttpeds\ttraj\tsimNum\tselPop\tselGen\tselBegPop\tselBegGen\tselCoeff\tselFreq" > allinfo.full.tsv

  cat ~{paramFileCommon} ~{paramFile} > paramFileCombined
  grep -v "recomb_file" "paramFileCombined" > ~{simBlockId}.fixed.par
  echo "recomb_file ~{recombFile}" >> ~{simBlockId}.fixed.par

  for rep in `seq 1 ~{nSimsInBlock}`;
  do

    if [ "~{randomSeed}" -eq "0" ]; then
       cat /dev/urandom | od -vAn -N4 -tu4 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed 's/.$//' > "cosi2.${rep}.randseed"
    else
       echo "~{randomSeed}" > cosi2.${rep}.randseed
    fi
     
    ( env COSI_NEWSIM=1 COSI_MAXATTEMPTS=~{maxAttempts} COSI_SAVE_TRAJ="~{simBlockId}.${rep}.traj" COSI_SAVE_SWEEP_INFO="sweepinfo.${rep}.tsv" coalescent -p ~{simBlockId}.fixed.par -v -g -r $(cat "cosi2.${rep}.randseed") --genmapRandomRegions --drop-singletons .25 --tped "~{simBlockId}_${rep}_" ) || ( touch "${rep}.sim_failed"  )

    #echo -e 'simNum\tselPop\tselGen\tselBegPop\tselBegGen\tselCoeff\tselFreq' > sweepinfo.full.tsv
    #cat sweepinfo.tsv >> sweepinfo.full.tsv

    tar cvfz "~{simBlockId}.${rep}.tpeds.tar.gz" ~{simBlockId}_${rep}_*.tped
    echo -e "~{modelId}\t~{blockNum}\t${rep}\t1\t$(cat cosi2.${rep}.randseed)\t~{simBlockId}.${rep}.tpeds.tar.gz\t~{simBlockId}.${rep}.traj\t$(cat sweepinfo.${rep}.tsv)" >> allinfo.full.tsv
  done 
  >>>

  output {
    Array[ReplicaInfo] replicaInfos = read_objects("allinfo.full.tsv")

#    String      cosi2_docker_used = ""
  }
  runtime {
#    docker: "quay.io/ilya_broad/cms-dev:2.0.1-15-gd48e1db-is-cms2-new"
    docker: cosi2_docker
    memory: "3 GB"
    cpu: 2
    dx_instance_type: "mem1_ssd1_v2_x4"
    volatile: randomSeed==0
  }
}


workflow run_sims_cosi2 {
    meta {
      description: "Run a set of cosi2 simulations for one or more demographic models."
      author: "Ilya Shlyakhter"
      email: "ilya_shl@alum.mit.edu"
    }

    parameter_meta {
      paramFiles: "cosi2 parameter files specifying the demographic model (paramFileCommon is prepended to each)"
      recombFile: "Recombination map from which map of each simulated region is sampled"
      nreps: "Number of replicates for _each_ demographic model."
    }

    input {
      File paramFileCommon
      Array[File] paramFiles
      File recombFile
      Int nreps = 1
      Int nSimsPerBlock = 1
      String       cosi2_docker = "quay.io/ilya_broad/dockstore-tool-cosi2@sha256:11df3a646c563c39b6cbf71490ec5cd90c1025006102e301e62b9d0794061e6a"
    }
    Int nBlocks = nreps / nSimsPerBlock
    #Array[String] paramFileCommonLines = read_lines(paramFileCommonLines)

    scatter(paramFile in paramFiles) {
        scatter(blockNum in range(nBlocks)) {
            call cosi2_run_one_sim_block {
                input:
                   paramFileCommon = paramFileCommon,
                   paramFile = paramFile,
	           recombFile=recombFile,
                   modelId=basename(paramFile, ".par"),
	           simBlockId=basename(paramFile, ".par")+"_"+blockNum,
	           blockNum=blockNum,
	           nSimsInBlock=nSimsPerBlock,
	           cosi2_docker=cosi2_docker
            }
        }
    }

    output {
      Array[ReplicaInfo] replicaInfos = flatten(flatten(cosi2_run_one_sim_block.replicaInfos))
    }
}
