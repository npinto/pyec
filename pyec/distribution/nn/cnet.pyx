# cython: profile=True
# distutils: language = c++
"""
Copyright (C) 2012 Alan J Lockett

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

"""
cimport cython
import numpy as np
cimport numpy as np
from libcpp.vector cimport vector

ctypedef np.float_t FLOAT_t

cdef class RnnEvaluator:
    """A compiled RNN as a computable object. Takes a network in a form that
    is efficient to activate so that the network can be evaluated quickly.
    
    Produced by :class:`LayeredRnnGenotype`'s ``compile`` method.
    
    :param numNeurons: The number of neurons in the network, incl. bias, input,
                       output, and hidden
    :type numNeurons: ``int``
    :param inputs: A list of slices or indexes that can be applied to the
                   current state to set input values. The list should contain
                   one item per input layer, and each item should be capable
                   of being provided to ``__setitem__`` in order to set the
                   input values. So, for instance, an entry ``slice(5,10)``
                   at index ``2`` in the array would imply that the third
                   input layer state values are stored between the 5th and 10th
                   index in the state, and that the input layer contains
                   five values.
    :type inputs: A ``list`` of ``slice``s or ``int``s, potentially mixed
    :param outputs: A list of slices or indexes that can be applied to the
                    current state to extract output values. Like the structure
                    for ``inputs``, but used to retrieve outputs.
    :type outputs: A ``list`` of ``slice``s or ``int``s, potentially mixed
    :param weightStack: A list of lists of entries that apply the weights
                        of a neural network. Each entry contains a weight
                        matrix (``numpy.ndarray``), a ``slice`` indicating
                        the source indices, and a ``slice`` indicating the
                        target indices. Each nested list represents a set of
                        operations that may be performed concurrently, i.e.
                        that may be parallellized. Successive elements of the
                        outermost list must be performed serially.
    :type weightStack: A ``list`` of ``list``s each with a `tuple` containing
                       (``numpy.ndarray``, ``slice``, ``slice``)
    :param activationStack: A list of (``slice``,function) tuples that contains
                            the activation functions that must be applied for
                            each layer. The ``slice`` indicates the location of
                            the layer in the state array, and the function is
                            used to activate that portion of the state array.
    
    """
    
    def __init__(self, numNeurons, inputs, outputs, weightStack, activationStack):
        cdef list stepW
        cdef list frm
        cdef list to
        self.numNeurons = numNeurons
        self.inputs = inputs
        self.outputs = outputs
        self.stepWeights = []
        self.stepFrm = []
        self.stepTo = []
        for step in weightStack:
            stepW = []
            frm = []
            to = []
            for weights, frmIdxs, toIdxs in step:
                stepW.append(weights)
                frm.append(frmIdxs)
                to.append(toIdxs)
            self.stepWeights.append(stepW)
            self.stepFrm.append(frm)
            self.stepTo.append(to)
            
        self.activationStack = activationStack
        self.clear()
    
    @cython.boundscheck(False)    
    cpdef int clear(self) except? -1:
        """Reset the state of the network."""
        self.state = np.zeros(self.numNeurons, dtype=float)
        return 0
    
    @cython.boundscheck(False)    
    cpdef int setInputs(self, list inputs) except? -1:
        """Takes an array of arrays of floats and writes
        it into the state at the inputs
        
        :param inputs: a list of arrays of floats, with each nested array matching
                       the size of the input layer as specified in ``self.inputs``
        :type inputs: a list of arrays/lists of floats
        
        """
        cdef int size = len(self.inputs)
        cdef int i,j,idx
        #cdef pair[int,int] slc
        for i in xrange(size):
            slc = self.inputs[i]
            idx = slc.start
            for j in xrange(slc.stop - slc.start):
                self.state[idx] = inputs[i][j]
                idx += 1
        return 0
    
    @cython.boundscheck(False)
    cpdef list getOutputs(self):
        """Produces an array of floats corresponding to the outputs.
        
        :returns: a list of arrays of floats, with each nested array matching
                  the size of the input layer as specified in ``self.outputs``
        
        """
        cdef list ret = []
        cdef int size = len(self.outputs)
        cdef int i
        cdef object slc
        for i in xrange(size):
            slc = self.outputs[i]
            ret.append(self.state[slc])
        return ret
     
    @cython.boundscheck(False)
    cpdef int activate(self) except? -1:
        """Advance the network to the next state based on the current state."""
        cdef np.ndarray[FLOAT_t, ndim=1] next = np.zeros(self.numNeurons, dtype=np.float)
        cdef int size = len(self.stepWeights)
        cdef int i,j, size2
        cdef object frm, to, idxs, act
        for i in xrange(size):
            size2 = len(self.stepWeights[i])
            
            for j in xrange(size2):
               frm = self.stepFrm[i][j]
               to = self.stepTo[i][j]
               next[to] += np.dot(self.stepWeights[i][j], self.state[frm])
        
        for idxs, act in self.activationStack:
            next[idxs] = act(next[idxs])
        self.state = next
        return 0

    @cython.boundscheck(False)
    cpdef list call(self, list inputs, int times):
        cdef int i
        self.setInputs(inputs)
        for i in xrange(times):
            if self.activate() < 0:
                return None
        return self.getOutputs()
    
    def __call__(self, inputs, times=5):
        return self.call(inputs, times)