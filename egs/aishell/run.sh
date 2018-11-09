#!/bin/bash

stage=-1

dumpdir=dump   # directory to dump full features

# feature configuration
do_delta=false

# exp tag
tag="" # tag for managing experiments.

data=/home/ktxu/workspace/data/aishell

. utils/parse_options.sh || exit 1;
. ./cmd.sh
. ./path.sh

if [ $stage -le 0 ]; then
    echo "stage 0: Data Preparation"
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    # Generate wav.scp, text, utt2spk, spk2utt (segments)
    local/aishell_data_prep.sh $data/data_aishell/wav $data/data_aishell/transcript || exit 1;
    # remove space in text
    for x in train test dev; do
        cp data/${x}/text data/${x}/text.org
        paste -d " " <(cut -f 1 -d" " data/${x}/text.org) <(cut -f 2- -d" " data/${x}/text.org | tr -d " ") \
            > data/${x}/text
    done
fi

feat_train_dir=${dumpdir}/train/delta${do_delta}; mkdir -p ${feat_train_dir}
feat_test_dir=${dumpdir}/test/delta${do_delta}; mkdir -p ${feat_test_dir}
feat_dev_dir=${dumpdir}/dev/delta${do_delta}; mkdir -p ${feat_dev_dir}
if [ $stage -le 1 ]; then
    echo "stage 1: Feature Generation"
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    fbankdir=fbank
    for data in train test dev; do
        steps/make_fbank.sh --cmd "$train_cmd" --nj 20 --write_utt2num_frames true \
            data/$data exp/make_fbank/$data $fbankdir/$data || exit 1;
    done
    # compute global CMVN
    compute-cmvn-stats scp:data/train/feats.scp data/train/cmvn.ark
    # dump features for training
    for data in train test dev; do
        feat_dir=`eval echo '$feat_'${data}'_dir'`
        dump.sh --cmd "$train_cmd" --nj 20 --do_delta $do_delta \
            data/$data/feats.scp data/train/cmvn.ark exp/dump_feats/$data $feat_dir
    done
fi

dict=data/lang_1char/train_chars.txt
echo "dictionary: ${dict}"
nlsyms=data/lang_1char/non_lang_syms.txt
if [ $stage -le 2 ]; then
    echo "stage 2: Dictionary and Json Data Preparation"
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    mkdir -p data/lang_1char/

    echo "make a non-linguistic symbol list"
    # It's empty in AISHELL-1
    cut -f 2- data/train/text | grep -o -P '\[.*?\]' | sort | uniq > ${nlsyms}
    cat ${nlsyms}

    echo "make a dictionary"
    echo "<unk> 0" >  ${dict}
    echo "<sos> 1" >> ${dict}
    echo "<eos> 2" >> ${dict}
    text2token.py -s 1 -n 1 -l ${nlsyms} data/train/text | cut -f 2- -d" " | tr " " "\n" \
    | sort | uniq | grep -v -e '^\s*$' | awk '{print $0 " " NR+2}' >> ${dict}
    wc -l ${dict}

    echo "make json files"
    for data in train test dev; do
        feat_dir=`eval echo '$feat_'${data}'_dir'`
        data2json.sh --feat ${feat_dir}/feats.scp --nlsyms ${nlsyms} \
             data/$data ${dict} > ${feat_dir}/data.json
    done
fi

exit 0

if [ -z ${tag} ]; then
    expdir=exp/train #_${etype}_e${elayers}_unit${eunits}_proj${eprojs}_d${dlayers}_unit${dunits}_${atype}_aconvc${aconv_chans}_aconvf${aconv_filts}_mtlalpha${mtlalpha}_${opt}_sampprob${samp_prob}_bs${batchsize}_mli${maxlen_in}_mlo${maxlen_out}
    if ${do_delta}; then
        expdir=${expdir}_delta
    fi
else
    expdir=exp/${train_set}_${tag}
fi
mkdir -p ${expdir}

if [ ${stage} -le 4 ]; then
    echo "stage 4: Network Training"
    train.py \
      --train-json ../../test/data/data.json \
      --valid-json ../../test/data/data.json \
      --vocab ../../test/data/train_nodup_sp_units.txt \
      --einput 83 \
      --print-freq 1 \
      --checkpoint \
      --epochs 5 \
      --batch-size 2
fi