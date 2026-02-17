#!binbash
# Batch process a whole folder for mastering only
for f in .raw_samples.wav; do
    .IRConvolverPro-CLI -i1 $f -o .mastered$(basename $f) -r 48000 -b 24 --agc
done
echo All samples mastered and resampled.
