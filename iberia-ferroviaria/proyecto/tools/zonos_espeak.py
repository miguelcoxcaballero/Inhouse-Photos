# Configura phonemizer para usar la biblioteca espeak-ng del paquete espeakng-loader (castellano: «es»).
import os, espeakng_loader
os.environ['PHONEMIZER_ESPEAK_LIBRARY'] = espeakng_loader.get_library_path()
os.environ['ESPEAK_DATA_PATH'] = espeakng_loader.get_data_path()
from phonemizer.backend.espeak.wrapper import EspeakWrapper
EspeakWrapper.set_library(espeakng_loader.get_library_path())
