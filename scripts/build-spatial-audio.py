"""Original eight-second demo loop, generated offline, not downloaded music."""
from pathlib import Path
import numpy as np
import wave
rate=24000
audio=np.zeros(rate*8,np.float64)
for i,note in enumerate([48,55,60,64,48,55,62,67,45,52,57,60,43,50,55,62]):
    t=np.arange(int(rate*0.49))/rate
    freq=440*2**((note-69)/12)
    signal=(np.sin(2*np.pi*freq*t)+0.25*np.sin(4*np.pi*freq*t))*np.exp(-t*7)*np.minimum(1,t/0.008)
    start=i*rate//2;audio[start:start+len(t)]+=signal*0.17
audio=np.clip(audio,-0.8,0.8)
file=Path(__file__).resolve().parents[1]/'JarvisPhone/Resources/Spatial_demo.wav'
with wave.open(str(file),'wb') as w:
    w.setnchannels(1);w.setsampwidth(2);w.setframerate(rate);w.writeframes((audio*32767).astype('<i2').tobytes())
print(file.name,len(audio)/rate,'seconds; peak',float(abs(audio).max()))
