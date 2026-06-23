CXXFLAGS ?= -std=c++17 -O2 $(shell curl-config --cflags)
LDLIBS ?= $(shell curl-config --libs)

run: app ## build and run the demo app
	./app

app: main.cpp
	$(CXX) $(CXXFLAGS) main.cpp -o app $(LDLIBS)

clean:
	rm -f app
