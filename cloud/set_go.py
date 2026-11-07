import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'^go \d+\.\d+(\.\d+)?$', 'go 1.22.0', s, count=1, flags=re.M)
s = re.sub(r'^toolchain .*\n', '', s, flags=re.M)
open(p, 'w', encoding='utf-8').write(s)
print('go directive -> 1.22.0')
