import numpy as np
from copy import copy, deepcopy

class MaskedView(object):
    
    def __init__(self, mask, data, fill_value=None):

        mask = mask.astype('bool')
        if data.shape[0] != mask.sum():
            raise ValueError('the number of data elements does not match mask') 
        self._data = data
        self.fill_value = fill_value
        self.base = None
        self._imask = np.empty(mask.shape, 'int32')
        self._imask.fill(-1)
        self._imask[mask] = np.arange(data.shape[0])
    
    @property
    def mask(self):
        return self._imask >= 0

    @property
    def dtype(self):
        return self._data.dtype

    @property
    def shape_contents(self):
        return self._data.shape[1:]

    def filled(self):
        out_arr = np.empty(self.shape + self.shape_contents, self.dtype)
        out_arr.fill(self.fill_value)
        out_arr[self.mask] = self.__array__()
        return out_arr

    def _get_shape(self):
        return self._imask.shape

    def _set_shape(self, value):
        self._imask.shape = value

    shape = property(_get_shape, _set_shape, "Tuple of array dimensions")

    def get_size(self):
        return self.mask.sum()

    def copy(self):
        data = self._data[self._imask[self.mask]]
        return ModelParams(self.mask, data, self.fill_value)

    def __getitem__(self, index):
        imask = self._imask[index]
        if isinstance(imask, int):
            if imask >= 0:
                return self._data[imask]
            else:
                return self.fill_value
        else:
            new_mp = copy(self)
            new_mp._imask = self._imask[index]
            if self.base is None:
                new_mp.base = self
            return new_mp
    
    def __setitem__(self, index, values):
        imask = self._imask[index]
        if isinstance(imask, int):
            if imask >= 0:
                self._data[imask] = values
            else:
                self._imask[index]=self._data.shape[0]
                self._data = np.r_[self._data, values[np.newaxis]]
                self.size =+ 1
        else:
            self._data[imask[imask >= 0]] = values

    def __iter__(self):
        return self.__array__().__iter__()

    def __array__(self, dtype=None):

        #to save time only index _data when base is not None
        if self.base is None:
            data = self._data
        else:
            data = self._data[self._imask[self.mask]]

        #only makes a copy of data when dtype does not match self.dtype
        if dtype is None or np.dtype(dtype) == self.dtype:
            return data
        else:
            return data.astype(dtype)

    def __array_wrap__(self, array, context=None):
        #fill_value is not updated
        #ie if new = old + 1 new.fill_value == old.fil_value. Fixing this might
        #be a useful feature to implement at some point for numeric fill_values
        new_container = MaskedView(self.mask, array, self.fill_value)
        return new_container