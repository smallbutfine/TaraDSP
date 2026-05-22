./TaraDSP -i1 src.wav -i2 cab.wav -o out.wav
if [ $? -eq 0 ]; then
    echo "Success!"
else
    echo "Processing failed with code $?"
fi
