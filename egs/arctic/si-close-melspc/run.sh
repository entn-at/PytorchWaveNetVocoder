#!/bin/bash
############################################################
#        SCRIPT TO BUILD SI-CLOSE WAVENET VOCODER          #
############################################################

# Copyright 2017 Tomoki Hayashi (Nagoya University)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# USER SETTINGS {{{
#######################################
#           STAGE SETTING             #
#######################################
stage=0123456
# 0: data preparation step
# 1: feature extraction step
# 2: statistics calculation step
# 3: noise weighting step
# 4: training step
# 5: decoding step
# 6: noise shaping step

#######################################
#          FEATURE SETTING            #
#######################################
feature_type=melspc            # world or melspc (in this recipe fixed to "melspc")
spks=(bdl rms clb slt ksp jmk) # target speakers
shiftms=5                      # shift length in msec
fftl=1024                      # fft length
highpass_cutoff=70             # highpass filter cutoff frequency (if 0, will not apply)
fs=16000                       # sampling rate
mspc_dim=80                    # dimension of mel-spectrogram
mcep_dim=25                    # dimension of mel-cepstrum
mcep_alpha=0.410               # alpha value of mel-cepstrum
fmin=""                        # minimum frequency in melspc calculation
fmax=""                        # maximum frequency in melspc calculation
use_noise_shaping=true         # whether to use noise shaping
mag=0.5                        # strength of noise shaping (0.0 < mag <= 1.0)
n_jobs=10                      # number of parallel jobs

#######################################
#          TRAINING SETTING           #
#######################################
n_gpus=1                  # number of gpus
n_quantize=256            # number of quantization of waveform
n_aux=80                  # number of auxiliary features
n_resch=512               # number of residual channels
n_skipch=256              # number of skip channels
dilation_depth=10         # dilation depth (e.g. if set 10, max dilation = 2^(10-1))
dilation_repeat=3         # number of dilation repeats
kernel_size=2             # kernel size of dilated convolution
lr=1e-4                   # learning rate
weight_decay=0.0          # weight decay coef
iters=200000              # number of iterations
batch_length=20000        # batch length
batch_size=1              # batch size
checkpoint_interval=10000 # save model per this number
use_upsampling=true       # whether to use upsampling layer
resume=""                 # checkpoint path to resume (Optional)

#######################################
#          DECODING SETTING           #
#######################################
outdir=""            # directory to save decoded wav dir (Optional)
checkpoint=""        # checkpoint path to be used for decoding (Optional)
config=""            # model configuration path (Optional)
stats=""             # statistics path (Optional)
feats=""             # list or directory of feature files (Optional)
decode_batch_size=32 # batch size in decoding

#######################################
#            OTHER SETTING            #
#######################################
ARCTIC_DB_ROOT=downloads # directory including DB (if DB not exists, will be downloaded)
tag=""                   # tag for network directory naming (Optional)

# parse options
. parse_options.sh || exit 1;

# check feature type
if [ ${feature_type} != "melspc" ]; then
    echo "This recipe does not support feature_type=\"world\"." 2>&1
    echo "Please try the egs/arctic/si-close." 2>&1
    exit 1;
fi

# set directory names
train=tr_"$(IFS=_; echo "${spks[*]}")"
eval=ev_"$(IFS=_; echo "${spks[*]}")"

# stop when error occurred
set -euo pipefail
# }}}


# STAGE 0 {{{
if echo ${stage} | grep -q 0 ;then
    echo "###########################################################"
    echo "#                 DATA PREPARATION STEP                   #"
    echo "###########################################################"
    if [ ! -e ${ARCTIC_DB_ROOT}/.done ];then
        mkdir -p ${ARCTIC_DB_ROOT}
        cd ${ARCTIC_DB_ROOT}
        for id in bdl slt rms clb jmk ksp awb;do
            wget http://festvox.org/cmu_arctic/cmu_arctic/packed/cmu_us_${id}_arctic-0.95-release.tar.bz2
            tar xf cmu_us_${id}*.tar.bz2
        done
        rm ./*.tar.bz2
        cd ../
        touch ${ARCTIC_DB_ROOT}/.done
        echo "database is successfully downloaded."
    fi
    [ ! -e "data/local" ] && mkdir -p "data/local"
    [ ! -e "data/${train}" ] && mkdir -p "data/${train}"
    [ ! -e "data/${eval}" ] && mkdir -p "data/${eval}"
    [ -e "data/${train}/wav.scp" ] && rm "data/${train}/wav.scp"
    [ -e "data/${eval}/wav.scp" ] && rm "data/${eval}/wav.scp"
    for spk in "${spks[@]}";do
        find "${ARCTIC_DB_ROOT}/cmu_us_${spk}_arctic/wav" -name "*.wav" \
            | sort > "data/local/wav.${spk}.scp"
        head -n 1028 "data/local/wav.${spk}.scp" >> "data/${train}/wav.scp"
        tail -n 104 "data/local/wav.${spk}.scp" >> "data/${eval}/wav.scp"
    done
    echo "making wav list for training is successfully done. (#training = $(wc -l < data/${train}/wav.scp))"
    echo "making wav list for evaluation is successfully done. (#evaluation = $(wc -l < data/${eval}/wav.scp))"
fi
# }}}


# STAGE 1 {{{
if echo ${stage} | grep -q 1 ;then
    echo "###########################################################"
    echo "#               FEATURE EXTRACTION STEP                   #"
    echo "###########################################################"
    nj=0
    for set in ${train} ${eval};do
        for spk in "${spks[@]}";do
            [ ! -e "exp/feature_extract/${set}" ] && mkdir -p "exp/feature_extract/${set}"
            # make scp of each speaker
            scp=exp/feature_extract/${set}/wav.${spk}.scp
            grep ${spk} "data/${set}/wav.scp" > "${scp}"

            # feature extract
            ${train_cmd} --num-threads ${n_jobs} \
                "exp/feature_extract/feature_extract_${feature_type}_${set}.${spk}.log" \
                feature_extract.py \
                    --waveforms "${scp}" \
                    --wavdir "wav_hpf/${set}/${spk}" \
                    --hdf5dir "hdf5/${set}/${spk}" \
                    --feature_type ${feature_type} \
                    --fs ${fs} \
                    --shiftms ${shiftms} \
                    --mspc_dim ${mspc_dim} \
                    --highpass_cutoff ${highpass_cutoff} \
                    --fftl ${fftl} \
                    --fmin "${fmin}" \
                    --fmax "${fmax}" \
                    --n_jobs ${n_jobs} &

            # update job counts
            nj=$(( nj + 1  ))
            if [ ! "${max_jobs}" -eq -1 ] && [ "${max_jobs}" -eq ${nj} ];then
                wait
                nj=0
            fi
        done
        wait

        nj=0
        for spk in "${spks[@]}";do
            # extract stft-baed mel-cepstrum for noise shaping
            scp=exp/feature_extract/${set}/wav.${spk}.scp
            if [ "${set}" = "${train}" ] && ${use_noise_shaping};then
                ${train_cmd} --num-threads ${n_jobs} \
                    "exp/feature_extract/feature_extract_mcep_${set}.${spk}.log" \
                    feature_extract.py \
                        --waveforms "${scp}" \
                        --wavdir "wav_hpf/${set}/${spk}" \
                        --hdf5dir "hdf5/${set}/${spk}" \
                        --feature_type mcep \
                        --fs ${fs} \
                        --shiftms ${shiftms} \
                        --mcep_dim ${mcep_dim} \
                        --mcep_alpha ${mcep_alpha} \
                        --highpass_cutoff ${highpass_cutoff} \
                        --save_wav false \
                        --fftl ${fftl} \
                        --n_jobs ${n_jobs} &

                # update job counts
                nj=$(( nj + 1  ))
                if [ ! "${max_jobs}" -eq -1 ] && [ "${max_jobs}" -eq ${nj} ];then
                    wait
                    nj=0
                fi
            fi
        done
        wait

        # check the number of feature files
        n_wavs=$(wc -l "data/${set}/wav.scp")
        n_feats=$(find "hdf5/${set}" -name "*.h5" | wc -l)
        echo "${n_feats}/${n_wavs} files are successfully processed."

        # make scp files
        if [ ${highpass_cutoff} -eq 0 ];then
            cp "data/${set}/wav.scp" "data/${set}/wav_hpf.scp"
        else
            find "wav_hpf/${set}" -name "*.wav" | sort > "data/${set}/wav_hpf.scp"
        fi
        find "hdf5/${set}" -name "*.h5" | sort > "data/${set}/feats.scp"
    done
fi
# }}}


# STAGE 2 {{{
if echo ${stage} | grep -q 2 ;then
    echo "###########################################################"
    echo "#              CALCULATE STATISTICS STEP                  #"
    echo "###########################################################"
    ${train_cmd} "exp/calculate_statistics/calc_stats_${feature_type}_${train}.log" \
        calc_stats.py \
            --feats "data/${train}/feats.scp" \
            --stats "data/${train}/stats.h5" \
            --feature_type ${feature_type}
    if ${use_noise_shaping};then
        ${train_cmd} "exp/calculate_statistics/calc_stats_mcep_${train}.log" \
            calc_stats.py \
                --feats "data/${train}/feats.scp" \
                --stats "data/${train}/stats.h5" \
                --feature_type mcep
    fi
    echo "statistics are successfully calculated."
fi
# }}}


# STAGE 3 {{{
if echo ${stage} | grep -q 3  && ${use_noise_shaping};then
    echo "###########################################################"
    echo "#                  NOISE WEIGHTING STEP                   #"
    echo "###########################################################"
    nj=0
    [ ! -e exp/noise_shaping ] && mkdir -p exp/noise_shaping
    for spk in "${spks[@]}";do
        # make scp of each speaker
        scp=exp/noise_shaping/wav_hpf.${spk}.scp
        grep "\/${spk}\/" "data/${train}/wav_hpf.scp" > ${scp}

        # apply noise shaping
        ${train_cmd} --num-threads ${n_jobs} \
            exp/noise_shaping/noise_shaping_apply_mcep.${spk}.log \
            noise_shaping.py \
                --waveforms ${scp} \
                --stats "data/${train}/stats.h5" \
                --outdir "wav_nwf/${train}/${spk}" \
                --feature_type mcep \
                --fs ${fs} \
                --shiftms ${shiftms} \
                --mcep_dim_start 2 \
                --mcep_dim_end $(( 2 + mcep_dim +1 )) \
                --mcep_alpha ${mcep_alpha} \
                --mag ${mag} \
                --inv true \
                --n_jobs ${n_jobs} &

        # update job counts
        nj=$(( nj + 1  ))
        if [ ! "${max_jobs}" -eq -1 ] && [ "${max_jobs}" -eq ${nj} ];then
            wait
            nj=0
        fi
    done
    wait

    # check the number of feature files
    n_wavs=$(wc -l "data/${train}/wav_hpf.scp")
    n_ns=$(find "wav_nwf/${train}" -name "*.wav" | wc -l)
    echo "${n_ns}/${n_wavs} files are successfully processed."

    # make scp files
    find "wav_nwf/${train}" -name "*.wav" | sort > "data/${train}/wav_nwf.scp"
fi
# }}}


# STAGE 4 {{{
# set variables
if [ ! -n "${tag}" ];then
    expdir=exp/tr_arctic_16k_si_close_${feature_type}_nq${n_quantize}_na${n_aux}_nrc${n_resch}_nsc${n_skipch}_ks${kernel_size}_dp${dilation_depth}_dr${dilation_repeat}_lr${lr}_wd${weight_decay}_bl${batch_length}_bs${batch_size}
    if ${use_noise_shaping};then
        expdir=${expdir}_ns
    fi
    if ${use_upsampling};then
        expdir=${expdir}_up
    fi
else
    expdir=exp/tr_arctic_${tag}
fi
if echo ${stage} | grep -q 4 ;then
    echo "###########################################################"
    echo "#               WAVENET TRAINING STEP                     #"
    echo "###########################################################"
    if ${use_noise_shaping};then
        waveforms=data/${train}/wav_nwf.scp
    else
        waveforms=data/${train}/wav_hpf.scp
    fi
    upsampling_factor=$(echo "${shiftms} * ${fs} / 1000" | bc)
    [ ! -e ${expdir}/log ] && mkdir -p ${expdir}/log
    [ ! -e ${expdir}/stats.h5 ] && cp -v data/${train}/stats.h5 ${expdir}
    ${cuda_cmd} --gpu ${n_gpus} "${expdir}/log/train_${train}.log" \
        train.py \
            --n_gpus ${n_gpus} \
            --waveforms "${waveforms}" \
            --feats "data/${train}/feats.scp" \
            --stats "data/${train}/stats.h5" \
            --expdir "${expdir}" \
            --feature_type ${feature_type} \
            --n_quantize ${n_quantize} \
            --n_aux ${n_aux} \
            --n_resch ${n_resch} \
            --n_skipch ${n_skipch} \
            --dilation_depth ${dilation_depth} \
            --dilation_repeat ${dilation_repeat} \
            --kernel_size ${kernel_size} \
            --lr ${lr} \
            --weight_decay ${weight_decay} \
            --iters ${iters} \
            --batch_length ${batch_length} \
            --batch_size ${batch_size} \
            --checkpoint_interval ${checkpoint_interval} \
            --upsampling_factor "${upsampling_factor}" \
            --use_upsampling_layer ${use_upsampling} \
            --resume "${resume}"
fi
# }}}


# STAGE 5 {{{
[ ! -n "${outdir}" ] && outdir=${expdir}/wav
[ ! -n "${checkpoint}" ] && checkpoint=${expdir}/checkpoint-final.pkl
[ ! -n "${config}" ] && config=$(dirname ${checkpoint})/model.conf
[ ! -n "${stats}" ] && stats=$(dirname ${checkpoint})/stats.h5
[ ! -n "${feats}" ] && feats=data/${eval}/feats.scp
if echo ${stage} | grep -q 5 ;then
    echo "###########################################################"
    echo "#               WAVENET DECODING STEP                     #"
    echo "###########################################################"
    [ ! -e exp/decoding ] && mkdir -p exp/decoding
    nj=0
    for spk in "${spks[@]}";do
        # make scp of each speaker
        scp=exp/decoding/feats.${spk}.scp
        grep "\/${spk}\/" "$feats" > ${scp}

        # decode
        ${cuda_cmd} --gpu ${n_gpus} "${outdir}/log/decode.${spk}.log" \
            decode.py \
                --n_gpus ${n_gpus} \
                --feats ${scp} \
                --stats ${stats} \
                --outdir "${outdir}/${spk}" \
                --checkpoint "${checkpoint}" \
                --config "${config}" \
                --fs ${fs} \
                --batch_size ${decode_batch_size} &

        # update job counts
        nj=$(( nj + 1  ))
        if [ ! "${max_jobs}" -eq -1 ] && [ "${max_jobs}" -eq ${nj} ];then
            wait
            nj=0
        fi
    done
    wait
fi
# }}}


# STAGE 6 {{{
if echo ${stage} | grep -q 6  && ${use_noise_shaping};then
    echo "###########################################################"
    echo "#                  NOISE SHAPING STEP                     #"
    echo "###########################################################"
    nj=0
    for spk in "${spks[@]}";do
        # make scp of each speaker
        scp=${outdir}/${spk}/wav.scp
        find "${outdir}/${spk}" -name "*.wav" | grep "\/${spk}\/" | sort > ${scp}

        # restore noise shaping
        ${train_cmd} --num-threads ${n_jobs} \
            exp/noise_shaping/noise_shaping_restore_mcep.${spk}.log \
            noise_shaping.py \
                --waveforms ${scp} \
                --stats ${stats} \
                --outdir "${outdir}_nsf/${spk}" \
                --feature_type mcep \
                --fs ${fs} \
                --shiftms ${shiftms} \
                --mcep_alpha ${mcep_alpha} \
                --mag ${mag} \
                --inv false \
                --n_jobs ${n_jobs} &

        # update job counts
        nj=$(( nj + 1  ))
        if [ ! "${max_jobs}" -eq -1 ] && [ "${max_jobs}" -eq ${nj} ];then
            wait
            nj=0
        fi
    done
    wait
fi
# }}}
